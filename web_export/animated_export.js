// Browser-side H.264 MP4 encoder. Requires WebCodecs and an internet connection
// to load mp4-muxer. No images or video are uploaded to a server.
window.exportAnimatedMeme = async function (json) {
  if (!('VideoEncoder' in window) || !('VideoFrame' in window)) {
    throw new Error('MP4 export needs a recent Chrome or Edge browser with WebCodecs.');
  }
  const project = JSON.parse(json);
  const width = 720, height = 1280, fps = 30, seconds = 6;
  const codec = 'avc1.42001f';
  const support = await VideoEncoder.isConfigSupported({
    codec, width, height, bitrate: 2500000, framerate: fps,
    avc: { format: 'avc' }
  });
  if (!support.supported) throw new Error('H.264 encoding is not supported in this browser.');
  const { Muxer, ArrayBufferTarget } = await import(
    'https://esm.sh/mp4-muxer@5.2.2'
  );
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
  encoder.configure({
    codec, width, height, bitrate: 2500000, framerate: fps,
    avc: { format: 'avc' }
  });
  const canvas = document.createElement('canvas');
  canvas.width = width; canvas.height = height;
  const ctx = canvas.getContext('2d', { alpha: false });
  const holders = document.createElement('div');
  holders.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0;pointer-events:none';
  document.body.appendChild(holders);
  const images = [];
  try {
    for (const layer of project.layers) {
      const img = new Image();
      img.src = 'data:image/' + (layer.name.toLowerCase().endsWith('.gif') ? 'gif' :
        layer.name.toLowerCase().endsWith('.webp') ? 'webp' : 'png') +
        ';base64,' + layer.bytes;
      holders.appendChild(img);
      await img.decode();
      images.push(img);
    }
    // Draw a square editor canvas, centered inside a 9:16 WhatsApp Status video.
    const square = width;
    const top = (height - square) / 2;
    const scale = square / (project.canvasWidth || 400);
    const font = project.captionFont || 'Roboto';
    const bg = '#' + (project.background >>> 0).toString(16).padStart(8, '0').slice(2);
    const fg = '#' + (project.textColor >>> 0).toString(16).padStart(8, '0').slice(2);
    for (let i = 0; i < fps * seconds; i++) {
      if (failure) throw failure;
      const begin = performance.now();
      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, width, height);
      ctx.save();
      ctx.beginPath(); ctx.rect(0, top, square, square); ctx.clip();
      project.layers.forEach((layer, index) => {
        const x = layer.x * scale, y = top + layer.y * scale;
        const size = layer.size * scale;
        ctx.save();
        ctx.translate(x + size / 2, y + size / 2);
        ctx.rotate(layer.angle || 0);
        ctx.drawImage(images[index], -size / 2, -size / 2, size, size);
        ctx.restore();
      });
      ctx.fillStyle = fg;
      ctx.textAlign = 'center';
      ctx.textBaseline = 'top';
      ctx.font = '900 ' + (project.captionSize * scale) + 'px "' + font.replace(/"/g, '') + '"';
      const tx = (project.captionX + (project.canvasWidth - project.captionX) / 2) * scale;
      const ty = top + project.captionY * scale;
      const maxWidth = (project.canvasWidth - project.captionX) * scale;
      const words = (project.caption || '').split(/\s+/);
      let line = '', row = 0;
      for (const word of words) {
        const next = line ? line + ' ' + word : word;
        if (line && ctx.measureText(next).width > maxWidth) {
          ctx.fillText(line, tx, ty + row * project.captionSize * scale * 1.2);
          row++; line = word;
        } else line = next;
      }
      if (line) ctx.fillText(line, tx, ty + row * project.captionSize * scale * 1.2);
      ctx.restore();
      const frame = new VideoFrame(canvas, { timestamp: Math.round(i * 1000000 / fps) });
      encoder.encode(frame, { keyFrame: i % (fps * 2) === 0 });
      frame.close();
      // Let GIF / animated WebP advance in the browser before capturing the next frame.
      await new Promise(resolve => setTimeout(resolve,
        Math.max(0, 1000 / fps - (performance.now() - begin))));
    }
    await encoder.flush();
    if (failure) throw failure;
    muxer.finalize();
    const blob = new Blob([target.buffer], { type: 'video/mp4' });
    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url; a.download = 'animated-meme-whatsapp-status.mp4';
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
  } finally {
    encoder.close();
    holders.remove();
  }
};
