import { defineConfig } from 'vite';
import type { Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { readFile } from 'node:fs/promises';
import { basename, join } from 'node:path';
import { fileURLToPath, URL } from 'node:url';

/**
 * The rack pictures live in the resource's own images/ folder (the inventory's icons), and the page
 * asks for them as ../../images/<item>.png: in the game that is nui://sd-gunracks/images/<item>.png,
 * which fxmanifest.lua sends. The dev server's root is web/, so the same URL arrives here as
 * /images/<item>.png, and this hands it the file from ../images. Dev only: the build never bundles a
 * copy of them.
 */
const rackPictures = (): Plugin => ({
  name: 'sd-gunracks-rack-pictures',
  apply: 'serve',
  configureServer(server) {
    const dir = fileURLToPath(new URL('../images', import.meta.url));
    server.middlewares.use('/images', (req, res, next) => {
      const name = basename(decodeURIComponent((req.url ?? '').split('?')[0]));
      if (!/^[\w-]+\.png$/.test(name)) return next();
      readFile(join(dir, name))
        .then(data => {
          res.setHeader('Content-Type', 'image/png');
          res.end(data);
        })
        .catch(() => next());
    });
  },
});

export default defineConfig({
  plugins: [react(), rackPictures()],

  // Relative, because NUI loads the page off nui://sd-gunracks/web/build/index.html rather than
  // off a web root: an absolute '/assets/...' resolves to nothing there.
  base: './',

  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
  },

  build: {
    outDir: 'build',
    emptyOutDir: true,
    assetsDir: 'assets',

    // FiveM's CEF is Chromium 103-ish; nothing here needs syntax newer than chrome108's.
    target: 'chrome108',

    // Vite's default, written down on purpose: the typefaces have to be emitted as files the
    // manifest can glob, never inlined into the entry chunk CEF parses before it can paint anything.
    assetsInlineLimit: 4096,

    rollupOptions: {
      // Content-hashed names: CEF caches assets by URL, so an unhashed name is served stale across
      // restarts and an edit that built cleanly simply does not appear.
      output: {
        entryFileNames: 'assets/[name]-[hash].js',
        chunkFileNames: 'assets/[name]-[hash].js',
        assetFileNames: 'assets/[name]-[hash].[ext]',
      },
    },
  },

  server: {
    fs: { allow: ['..'] },
  },
});
