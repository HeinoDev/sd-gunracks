"""DDS writers for the three maps GTA's normal_spec.sps samples, with numpy BC encoders (no external tools).

What the game reads (CodeWalker.Shaders/BasicPS.hlsl + Common.hlsli, a transcription of the game's own shader):

    BumpSampler  n.xy = tex.xy * 2 - 1;  n.z = sqrt(1 - dot(n.xy, n.xy))      -> only R and G are used
    SpecSampler  intensity = dot(tex.rgb^2 (r and g squared), specMapIntMask)  -> R (mask is 1,0,0), squared
                 exponent  = tex.a * specularFalloffMult                         -> alpha is the gloss

so:
    diffuse   BC1 / DXT1           colour, no alpha
    normal    BC5 / ATI2 ("DXN")   X in R, Y in G as two independent 8-bit channels, exactly what .xy reads;
                                   Y is stored DirectX-style (green = -V), which is why Sollumz flips green on
                                   import. Z is rebuilt by the shader. DXT5 or DXT1 would quantise X to 5 bits.
    specular  BC3 / DXT5           RGB = sqrt(intensity) (the shader squares it), A = gloss, which needs alpha
Every chain has its mips down to 4 x 4; a normal map's mips are renormalised at each level.
"""
import math
import os
import struct

import numpy as np


def _blocks(a):
    """(h, w, c) -> (n, 16, c), 4 x 4 blocks in raster order."""
    h, w, c = a.shape
    return a.reshape(h // 4, 4, w // 4, 4, c).transpose(0, 2, 1, 3, 4).reshape(-1, 16, c)


def bc1_blocks(rgb):
    """uint8 (h, w, 3) -> raw BC1 block bytes (always the four-colour mode)."""
    b = _blocks(rgb.astype(np.float32))
    mean = b.mean(axis=1, keepdims=True)
    d = b - mean
    cov = np.einsum('nij,nik->njk', d, d)
    axis = np.tile(np.array([0.299, 0.587, 0.114], np.float32), (b.shape[0], 1))
    for _ in range(6):
        axis = np.einsum('njk,nk->nj', cov, axis)
        axis /= np.maximum(np.linalg.norm(axis, axis=1, keepdims=True), 1e-6)
    t = np.einsum('nij,nj->ni', d, axis)
    lo = mean[:, 0, :] + axis * t.min(axis=1, keepdims=True)
    hi = mean[:, 0, :] + axis * t.max(axis=1, keepdims=True)

    def to565(c):
        c = np.clip(c, 0, 255)
        return ((np.round(c[:, 0] * 31 / 255).astype(np.uint16) << 11)
                | (np.round(c[:, 1] * 63 / 255).astype(np.uint16) << 5)
                | np.round(c[:, 2] * 31 / 255).astype(np.uint16))

    def from565(c):
        return np.stack([((c >> 11) & 31) * (255.0 / 31), ((c >> 5) & 63) * (255.0 / 63),
                         (c & 31) * (255.0 / 31)], axis=1).astype(np.float32)

    a, z = to565(hi), to565(lo)
    c0, c1 = np.maximum(a, z), np.minimum(a, z)
    p0, p1 = from565(c0), from565(c1)
    pal = np.stack([p0, p1, (2 * p0 + p1) / 3, (p0 + 2 * p1) / 3], axis=1)
    idx = ((b[:, :, None, :] - pal[:, None, :, :]) ** 2).sum(axis=3).argmin(axis=2).astype(np.uint32)
    idx[c0 == c1] = 0
    bits = (idx << (2 * np.arange(16, dtype=np.uint32))).sum(axis=1).astype(np.uint32)
    out = np.zeros(b.shape[0], dtype=[('c0', '<u2'), ('c1', '<u2'), ('i', '<u4')])
    out['c0'], out['c1'], out['i'] = c0, c1, bits
    return out


def bc4_blocks(ch):
    """uint8 (h, w) one channel -> raw BC4 block bytes (eight-value mode: a0 > a1)."""
    b = _blocks(ch[:, :, None].astype(np.float32))[:, :, 0]
    a0 = b.max(axis=1)
    a1 = b.min(axis=1)
    pal = np.stack([a0, a1] + [((7 - i) * a0 + i * a1) / 7 for i in range(1, 7)], axis=1)   # codes 0..7
    idx = np.abs(b[:, :, None] - pal[:, None, :]).argmin(axis=2).astype(np.uint64)
    idx[a0 == a1] = 0
    bits = (idx << (3 * np.arange(16, dtype=np.uint64))).sum(axis=1).astype(np.uint64)
    out = np.zeros(b.shape[0], dtype=[('a0', 'u1'), ('a1', 'u1'), ('i', 'u1', 6)])
    out['a0'] = np.round(a0).astype(np.uint8)
    out['a1'] = np.round(a1).astype(np.uint8)
    for k in range(6):
        out['i'][:, k] = ((bits >> np.uint64(8 * k)) & np.uint64(0xFF)).astype(np.uint8)
    return out


def _pad4(a):
    """Tile a mip smaller than 4 px up to 4 (BC blocks are 4 x 4)."""
    h, w = a.shape[:2]
    if h >= 4 and w >= 4:
        return a
    return np.tile(a, (max(1, 4 // h), max(1, 4 // w)) + (1,) * (a.ndim - 2))[:max(4, h), :max(4, w)]


def _down(a):
    return (a[0::2, 0::2] + a[1::2, 0::2] + a[0::2, 1::2] + a[1::2, 1::2]) * 0.25


def _header(w, h, mips, fourcc, block_bytes):
    flags = 0x1 | 0x2 | 0x4 | 0x1000 | 0x20000 | 0x80000
    linear = max(1, w // 4) * max(1, h // 4) * block_bytes
    hdr = b'DDS ' + struct.pack('<7I', 124, flags, h, w, linear, 0, mips) + b'\x00' * 44
    hdr += struct.pack('<2I4s5I', 32, 0x4, fourcc, 0, 0, 0, 0, 0)
    hdr += struct.pack('<5I', 0x1000 | 0x8 | 0x400000, 0, 0, 0, 0)
    return hdr


def _chain(a, min_size=4):
    chain = [a]
    while min(chain[-1].shape[:2]) > min_size:
        chain.append(_down(chain[-1]))
    return chain


def _u8(a):
    return np.clip(a + 0.5, 0, 255).astype(np.uint8)


def write_bc1(path, rgb):
    """rgb: float (h, w, 3) 0..255 (sRGB values)."""
    body = b''.join(bc1_blocks(_pad4(_u8(m))).tobytes() for m in _chain(rgb))
    n = len(_chain(rgb))
    _save(path, _header(rgb.shape[1], rgb.shape[0], n, b'DXT1', 8) + body)


def write_bc3(path, rgba):
    """rgba: float (h, w, 4) 0..255. Colour block always in four-colour mode, alpha as BC4."""
    body = b''
    chain = _chain(rgba)
    for m in chain:
        m = _pad4(_u8(m))
        a = bc4_blocks(m[:, :, 3])
        c = bc1_blocks(m[:, :, :3])
        blk = np.zeros(len(a), dtype=[('a', a.dtype), ('c', c.dtype)])
        blk['a'], blk['c'] = a, c
        body += blk.tobytes()
    _save(path, _header(rgba.shape[1], rgba.shape[0], len(chain), b'DXT5', 16) + body)


def write_bc5(path, nrm):
    """nrm: float (h, w, 3) unit tangent-space normals, OpenGL convention (+Y = +V) as Blender bakes them.
    Stored X -> R, -Y -> G (DirectX), each mapped -1..1 -> 0..255; mips renormalised."""
    body = b''
    level = nrm
    levels = 0
    while True:
        v = level / np.maximum(np.linalg.norm(level, axis=2, keepdims=True), 1e-6)
        r = (v[:, :, 0] * 0.5 + 0.5) * 255.0
        g = (-v[:, :, 1] * 0.5 + 0.5) * 255.0
        rg = _pad4(np.stack([_u8(r), _u8(g)], axis=2))
        x, y = bc4_blocks(rg[:, :, 0]), bc4_blocks(rg[:, :, 1])
        blk = np.zeros(len(x), dtype=[('x', x.dtype), ('y', y.dtype)])
        blk['x'], blk['y'] = x, y
        body += blk.tobytes()
        levels += 1
        if min(level.shape[:2]) <= 4:
            break
        level = _down(v)
    _save(path, _header(nrm.shape[1], nrm.shape[0], levels, b'ATI2', 16) + body)


def _save(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, 'wb') as f:
        f.write(data)
    return path


def decode_bc4(data, w, h):
    """For self-tests: decode BC4 blocks back to uint8 (h, w)."""
    n = (w // 4) * (h // 4)
    blk = np.frombuffer(data[:n * 8], dtype=[('a0', 'u1'), ('a1', 'u1'), ('i', 'u1', 6)])
    a0, a1 = blk['a0'].astype(np.float32), blk['a1'].astype(np.float32)
    pal = np.stack([a0, a1] + [((7 - i) * a0 + i * a1) / 7 for i in range(1, 7)], axis=1)
    bits = np.zeros(n, np.uint64)
    for k in range(6):
        bits |= blk['i'][:, k].astype(np.uint64) << np.uint64(8 * k)
    idx = ((bits[:, None] >> (np.uint64(3) * np.arange(16, dtype=np.uint64))) & np.uint64(7)).astype(int)
    vals = np.take_along_axis(pal, idx, axis=1)
    return vals.reshape(h // 4, w // 4, 4, 4).transpose(0, 2, 1, 3).reshape(h, w)
