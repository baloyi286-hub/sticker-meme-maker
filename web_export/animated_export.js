// Export an animated meme as a locally encoded H.264 MP4.
// GIF and animated WebP frames are explicitly decoded; drawing an HTMLImageElement
// repeatedly does NOT reliably advance its animation on a canvas.
function stickerBytes(base64) {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function imageMime(bytes) {
  if (bytes.length >= 6 && String.fromCharCode(...bytes.slice(0, 6)).startsWith('GIF8')) {
    return 'image/gif';
  }
  if (bytes.length >= 12 &&
      String.fromCharCode(...bytes.slice(0, 4)) === 'RIFF' &&
      String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP') {
    return 'image/webp';
  }
  if (bytes.length >= 8 && bytes[0] === 137 && bytes[1] === 80 &&
      bytes[2] === 78 && bytes[3] === 71) {
    return 'image/png';
  }
  if (bytes[0] === 255 && bytes[1] === 216) return 'image/jpeg';
  throw new Error('Unsupported sticker image. Use PNG, JPEG, GIF or WebP.');
}

async function prepareSticker(layer) {
  const bytes = stickerBytes(layer.bytes);
  const type = imageMime(bytes);
  if ((type === 'image/gif' || type === 'image/webp') && 'ImageDecoder' in window &&
      await ImageDecoder.isTypeSupported(type)) {
    const decoder = new ImageDecoder({ data: bytes, type });
    try {
      await decoder.tracks.ready;
      const track = decoder.tracks.selectedTrack;
      if (!track) throw new Error('No image track found.');
      const frames = [];
      const durations = [];
      const count = Math.min(track.frameCount, 600);
      for (let i = 0; i < count; i++) {
        const result = await decoder.decode({ frameIndex: i, completeFramesOnly: true });
        // A VideoFrame can be drawn directly with CanvasRenderingContext2D.drawImage.
        frames.push(result.image);
        durations.push(Math.max(20000, result.image.duration || 100000));
      }
      if (!frames.length) throw new Error('No frames decoded.');
      const totalDuration = durations.reduce((sum, duration) => sum + duration, 0);
      return {
        frameAt(timeUs) {
          let elapsed = timeUs % totalDuration;
          for (let i = 0; i < frames.length; i++) {
            if (elapsed < durations[i]) return frames[i];
            elapsed -= durations[i];
          }
          return frames[frames.length - 1];
        },
        close() { for (const frame of frames) frame.close(); }
      };
    } finally {
      decoder.close();
    }
  }
  if (type === 'image/gif' || type === 'image/webp') {
    throw new Error('This browser cannot decode animated ' + type.split('/')[1] +
      '. Use a recent Chrome or Edge browser.');
  }
  const bitmap = await createImageBitmap(new Blob([bytes], { type }));
  return { frameAt() { return bitmap; }, close() { bitmap.close(); } };
}

// On iOS, ImageDecoder is unavailable even in Chrome. Record the browser's
// native animated image rendering rather than requiring that API.
function isMobilePlatform() {
  return /iPhone|iPad|iPod|Android/i.test(navigator.userAgent) ||
    (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

function supportedMp4RecorderType() {
  if (!('MediaRecorder' in window) || !('isTypeSupported' in MediaRecorder)) return null;
  return ['video/mp4;codecs=avc1.42E01E', 'video/mp4;codecs=avc1', 'video/mp4']
    .find(type => MediaRecorder.isTypeSupported(type)) || null;
}

let sharedWebPDecoder;

async function prepareNativeSticker(layer) {
  const bytes = stickerBytes(layer.bytes);
  const type = imageMime(bytes);
  if (type === 'image/webp') {
    if (typeof window.createWebPFrameDecoder !== 'function') {
      throw new Error('Animated WebP decoder was not loaded. Refresh the app.');
    }
    if (!sharedWebPDecoder) {
      sharedWebPDecoder = window.createWebPFrameDecoder();
      await sharedWebPDecoder.waitRuntime();
    }
    const animation = await sharedWebPDecoder.decodeFrames(bytes);
    if (!animation.frames.length) throw new Error('Animated WebP has no frames.');
    if (animation.width * animation.height * animation.frames.length > 90000000) {
      throw new Error('This animated sticker is too large to export on a phone.');
    }
    const frames = animation.frames.map(frame => {
      const rgba = new Uint8ClampedArray(frame.rgba.length * 4);
      for (let i = 0; i < frame.rgba.length; i++) {
        const pixel = frame.rgba[i] >>> 0;
        const offset = i * 4;
        rgba[offset] = pixel >>> 24;
        rgba[offset + 1] = (pixel >>> 16) & 255;
        rgba[offset + 2] = (pixel >>> 8) & 255;
        rgba[offset + 3] = pixel & 255;
      }
      const canvas = document.createElement('canvas');
      canvas.width = animation.width;
      canvas.height = animation.height;
      const ctx = canvas.getContext('2d');
      ctx.putImageData(new ImageData(rgba, animation.width, animation.height), 0, 0);
      return { canvas, duration: Math.max(20, frame.duration || 100) };
    });
    const totalMs = frames.reduce((sum, frame) => sum + frame.duration, 0);
    return {
      frameAt(timeUs) {
        let elapsed = (timeUs / 1000) % totalMs;
        for (const frame of frames) {
          if (elapsed < frame.duration) return frame.canvas;
          elapsed -= frame.duration;
        }
        return frames[frames.length - 1].canvas;
      },
      close() { frames.length = 0; }
    };
  }
  // Static PNG/JPEG can be drawn as-is. Animated GIF needs a separate
  // frame decoder; never silently export it as a still image.
  if (type === 'image/gif') {
    throw new Error('Animated GIF export on iPhone is not supported yet. Use an animated WebP sticker.');
  }
  const url = URL.createObjectURL(new Blob([bytes], { type }));
  const img = new Image();
  img.src = url;
  try { await img.decode(); }
  catch (error) { URL.revokeObjectURL(url); throw error; }
  return { frameAt() { return img; }, close() { URL.revokeObjectURL(url); } };
}

async function recordMobileMeme(project, render) {
  const mimeType = supportedMp4RecorderType();
  if (!mimeType) throw new Error('This mobile browser cannot record MP4. Try updating iOS.');
  const width = 720, height = 1280, fps = 30, seconds = 6;
  const canvas = document.createElement('canvas');
  canvas.width = width;
  canvas.height = height;
  if (typeof canvas.captureStream !== 'function') {
    throw new Error('This mobile browser cannot capture the meme canvas.');
  }
  const ctx = canvas.getContext('2d', { alpha: false });
  if (!ctx) throw new Error('Could not initialize mobile video canvas.');
  const stickers = [];
  let stream, recorder;
  try {
    for (const layer of project.layers) stickers.push(await prepareNativeSticker(layer));
    // Keep a live rendering loop; browsers advance GIF/WebP HTMLImageElements
    // with their own animation clocks. Unlike ImageDecoder this needs no WebCodecs.
    let animationStart = performance.now();
    const draw = () => render(ctx, project, stickers, (performance.now() - animationStart) * 1000, width, height);
    draw();
    stream = canvas.captureStream(fps);
    recorder = new MediaRecorder(stream, { mimeType, videoBitsPerSecond: 2500000 });
    const chunks = [];
    const completed = new Promise((resolve, reject) => {
      recorder.ondataavailable = event => { if (event.data.size) chunks.push(event.data); };
      recorder.onerror = event => reject(event.error || new Error('Mobile MP4 recording failed.'));
      recorder.onstop = () => chunks.length ? resolve(new Blob(chunks, { type: 'video/mp4' })) :
        reject(new Error('Mobile recorder produced an empty video.'));
    });
    recorder.start();
    const start = performance.now();
    animationStart = start;
    await new Promise((resolve, reject) => {
      function tick(now) {
        if (recorder.state === 'inactive') return reject(new Error('Recording stopped unexpectedly.'));
        draw();
        if (now - start < seconds * 1000) requestAnimationFrame(tick);
        else resolve();
      }
      requestAnimationFrame(tick);
    });
    recorder.stop();
    const blob = await completed;
    downloadMp4(blob);
  } finally {
    if (recorder && recorder.state !== 'inactive') recorder.stop();
    if (stream) stream.getTracks().forEach(track => track.stop());
    stickers.forEach(sticker => sticker.close());
  }
}

function downloadMp4(blob) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = 'animated-meme-whatsapp-status.mp4';
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}

function drawMemeFrame(ctx, project, stickers, timeUs, width, height) {
  const square = width;
  const top = (height - square) / 2;
  const editorWidth = project.canvasWidth || 400;
  const scale = square / editorWidth;
  const font = (project.captionFont || 'Roboto').replace(/"/g, '');
  const bg = '#' + (project.background >>> 0).toString(16).padStart(8, '0').slice(2);
  const fg = '#' + (project.textColor >>> 0).toString(16).padStart(8, '0').slice(2);
  ctx.fillStyle = '#000000';
  ctx.fillRect(0, 0, width, height);
  ctx.fillStyle = bg;
  ctx.fillRect(0, top, square, square);
  ctx.save();
  ctx.beginPath();
  ctx.rect(0, top, square, square);
  ctx.clip();
  project.layers.forEach((layer, index) => {
    const x = layer.x * scale, y = top + layer.y * scale;
    const size = layer.size * scale;
    ctx.save();
    ctx.translate(x + size / 2, y + size / 2);
    ctx.rotate(layer.angle || 0);
    ctx.drawImage(stickers[index].frameAt(timeUs), -size / 2, -size / 2, size, size);
    ctx.restore();
  });
  ctx.fillStyle = fg;
  ctx.textAlign = 'center';
  ctx.textBaseline = 'top';
  const textSize = (project.captionSize || 28) * scale;
  ctx.font = '900 ' + textSize + 'px "' + font + '"';
  const tx = (project.captionX + (editorWidth - project.captionX) / 2) * scale;
  const ty = top + project.captionY * scale;
  const maxWidth = Math.max(1, (editorWidth - project.captionX) * scale);
  const words = (project.caption || '').split(/\\s+/);
  let line = '', row = 0;
  for (const word of words) {
    const next = line ? line + ' ' + word : word;
    if (line && ctx.measureText(next).width > maxWidth) {
      ctx.fillText(line, tx, ty + row * textSize * 1.2);
      row++; line = word;
    } else line = next;
  }
  if (line) ctx.fillText(line, tx, ty + row * textSize * 1.2);
  ctx.restore();
}

window.exportAnimatedMeme = async function (json) {
  const project = JSON.parse(json);
  const needsNativeDecoder = project.layers.some(layer => {
    const type = imageMime(stickerBytes(layer.bytes));
    return type === 'image/webp' || type === 'image/gif';
  });
  if (isMobilePlatform() && needsNativeDecoder && !('ImageDecoder' in window)) {
    return recordMobileMeme(project, drawMemeFrame);
  }
  if (!('VideoEncoder' in window) || !('VideoFrame' in window)) {
    throw new Error('MP4 export requires WebCodecs in a recent Chrome or Edge browser.');
  }
  const width = 720, height = 1280, fps = 30, seconds = 6;
  const codec = 'avc1.42001f';
  const support = await VideoEncoder.isConfigSupported({
    codec, width, height, bitrate: 2500000, framerate: fps,
    avc: { format: 'avc' }
  });
  if (!support.supported) throw new Error('H.264 encoding is not supported by this browser.');

  const { Muxer, ArrayBufferTarget } = await import('https://esm.sh/mp4-muxer@5.2.2');
  const target = new ArrayBufferTarget();
  const muxer = new Muxer({
    target, video: { codec: 'avc', width, height }, fastStart: 'in-memory',
    firstTimestampBehavior: 'offset'
  });
  let failure;
  const encoder = new VideoEncoder({
    output: (chunk, meta) => muxer.addVideoChunk(chunk, meta),
    error: error => { failure = error; }
  });
  const stickers = [];
  try {
    encoder.configure({
      codec, width, height, bitrate: 2500000, framerate: fps,
      avc: { format: 'avc' }
    });
    for (const layer of project.layers) stickers.push(await prepareSticker(layer));

    const canvas = document.createElement('canvas');
    canvas.width = width; canvas.height = height;
    const ctx = canvas.getContext('2d', { alpha: false });
    if (!ctx) throw new Error('Could not create video drawing canvas.');
    for (let i = 0; i < fps * seconds; i++) {
      if (failure) throw failure;
      const timeUs = Math.round(i * 1000000 / fps);
      drawMemeFrame(ctx, project, stickers, timeUs, width, height);
      const frame = new VideoFrame(canvas, { timestamp: timeUs });
      encoder.encode(frame, { keyFrame: i % (fps * 2) === 0 });
      frame.close();
      if (encoder.encodeQueueSize > 8) await new Promise(resolve => setTimeout(resolve, 10));
    }
    await encoder.flush();
    if (failure) throw failure;
    muxer.finalize();
    const blob = new Blob([target.buffer], { type: 'video/mp4' });
    downloadMp4(blob);
  } finally {
    encoder.close();
    for (const sticker of stickers) sticker.close();
  }
};
