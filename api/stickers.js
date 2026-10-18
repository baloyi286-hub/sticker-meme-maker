import { list } from '@vercel/blob';
import { handleUpload } from '@vercel/blob/client';

const allowedTypes = ['image/png', 'image/jpeg', 'image/gif', 'image/webp'];
const maxSize = 12 * 1024 * 1024;

export default async function handler(req, res) {
  if (!process.env.BLOB_READ_WRITE_TOKEN) {
    return res.status(503).json({ error: 'Vercel Blob is not connected to this project.' });
  }

  if (req.method === 'GET') {
    try {
      const cursor = typeof req.query.cursor === 'string' ? req.query.cursor : undefined;
      const result = await list({ prefix: 'stickers/', limit: 100, cursor });
      res.setHeader('Cache-Control', 'no-store');
      return res.status(200).json({
        stickers: result.blobs.map(({ pathname, url, size, uploadedAt }) => ({
          pathname, url, size, uploadedAt
        })),
        cursor: result.cursor || null,
        hasMore: result.hasMore
      });
    } catch (error) {
      console.error('Sticker list failed:', error);
      return res.status(500).json({ error: 'Could not load shared stickers.' });
    }
  }

  if (req.method === 'POST') {
    // Tokens are restricted to supported images, 12 MB, and the stickers/ prefix.
    // This is a public gallery; introduce CAPTCHA / abuse prevention before broad launch.
    try {
      const result = await handleUpload({
        body: req.body,
        request: req,
        onBeforeGenerateToken: async (pathname) => {
          if (!/^stickers\/[a-f0-9]{64}\.(png|jpg|gif|webp)$/.test(pathname)) {
            throw new Error('Invalid sticker path.');
          }
          return {
            allowedContentTypes: allowedTypes,
            maximumSizeInBytes: maxSize,
            addRandomSuffix: false,
            allowOverwrite: false,
          };
        },
        onUploadCompleted: async () => {},
      });
      return res.status(200).json(result);
    } catch (error) {
      console.error('Sticker upload failed:', error);
      return res.status(400).json({ error: 'Sticker upload rejected.' });
    }
  }
  res.setHeader('Allow', 'GET, POST');
  return res.status(405).json({ error: 'Method not allowed.' });
}
