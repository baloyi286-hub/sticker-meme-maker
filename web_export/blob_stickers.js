// Client-side bridge between Flutter and Vercel Blob.
// Uses short-lived upload tokens issued by /api/stickers; never exposes the store token.
const blobSdk = () => import('https://esm.sh/@vercel/blob@1.1.1/client');

function decodeBase64(value) {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function detectType(bytes) {
  if (bytes[0] === 71 && bytes[1] === 73 && bytes[2] === 70) return ['image/gif', 'gif'];
  if (bytes[0] === 82 && bytes[1] === 73 && bytes[2] === 70 &&
      bytes[8] === 87 && bytes[9] === 69) return ['image/webp', 'webp'];
  if (bytes[0] === 137 && bytes[1] === 80 && bytes[2] === 78) return ['image/png', 'png'];
  if (bytes[0] === 255 && bytes[1] === 216) return ['image/jpeg', 'jpg'];
  throw new Error('Only PNG, JPEG, GIF and WebP stickers are supported.');
}

window.listSharedStickers = async function (cursor = '') {
  const response = await fetch('/api/stickers' +
    (cursor ? '?cursor=' + encodeURIComponent(cursor) : ''), { cache: 'no-store' });
  if (!response.ok) throw new Error((await response.json()).error || 'Cannot load stickers.');
  return JSON.stringify(await response.json());
};

window.uploadSharedSticker = async function (base64) {
  const bytes = decodeBase64(base64);
  if (bytes.length > 12 * 1024 * 1024) throw new Error('Sticker exceeds 12 MB.');
  const [type, ext] = detectType(bytes);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  const hash = Array.from(new Uint8Array(digest), b => b.toString(16).padStart(2, '0')).join('');
  const pathname = 'stickers/' + hash + '.' + ext;

  // Avoid re-uploading identical stickers already in the shared gallery.
  let cursor = '';
  do {
    const response = JSON.parse(await window.listSharedStickers(cursor));
    const existing = response.stickers.find(item => item.pathname === pathname);
    if (existing) return JSON.stringify(existing);
    cursor = response.hasMore ? response.cursor : '';
  } while (cursor);

  const { upload } = await blobSdk();
  const blob = await upload(pathname, new Blob([bytes], { type }), {
    access: 'public',
    handleUploadUrl: '/api/stickers',
    contentType: type,
    addRandomSuffix: false,
  });
  return JSON.stringify({ pathname: blob.pathname, url: blob.url });
};
