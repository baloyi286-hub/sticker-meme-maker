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

window.exportAnimatedMeme = async function (json) {
  if (!('VideoEncoder' in window) || !('VideoFrame' in window)) {
    throw new Error('MP4 export requires WebCodecs in a recent Chrome or Edge browser.');
  }
  const project = JSON.parse(json);
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
    const square = width;
    const top = (height - square) / 2;
    const editorWidth = project.canvasWidth || 400;
    const scale = square / editorWidth;
    const font = (project.captionFont || 'Roboto').replace(/"/g, '');
    const bg = '#' + (project.background >>> 0).toString(16).padStart(8, '0').slice(2);
    const fg = '#' + (project.textColor >>> 0).toString(16).padStart(8, '0').slice(2);

    for (let i = 0; i < fps * seconds; i++) {
      if (failure) throw failure;
      const timeUs = Math.round(i * 1000000 / fps);
      // Black letterboxing outside the square meme for portrait WhatsApp Status.
      ctx.fillStyle = '#000000';
      ctx.fillRect(0, 0, width, height);
      // Preserve the editor's chosen background only within its square canvas.
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
      const words = (project.caption || '').split(/\s+/);
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
      const frame = new VideoFrame(canvas, { timestamp: timeUs });
      encoder.encode(frame, { keyFrame: i % (fps * 2) === 0 });
      frame.close();
      if (encoder.encodeQueueSize > 8) await new Promise(resolve => setTimeout(resolve, 10));
    }
    await encoder.flush();
    if (failure) throw failure;
    muxer.finalize();
    const blob = new Blob([target.buffer], { type: 'video/mp4' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = 'animated-meme-whatsapp-status.mp4';
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
  } finally {
    encoder.close();
    for (const sticker of stickers) sticker.close();
  }
};
