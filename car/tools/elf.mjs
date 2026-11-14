// Minimal ELF32 ARM inspector: symbols + disassembly.
// usage: node elf.mjs <file> syms [regex]
//        node elf.mjs <file> dis <symbol|0xaddr> [count]
//        node elf.mjs <file> imports
//        node elf.mjs <file> xref <0xaddr>          (find words / literal refs equal to addr)
import fs from 'fs';
import { Capstone, Const, loadCapstone } from 'capstone-wasm';

const [,, file, cmd, arg, arg2] = process.argv;
const b = fs.readFileSync(file);
const u16 = o => b.readUInt16LE(o), u32 = o => b.readUInt32LE(o);

const shoff = u32(0x20), shentsize = u16(0x2e), shnum = u16(0x30), shstrndx = u16(0x32);
const secs = [];
for (let i = 0; i < shnum; i++) {
  const o = shoff + i * shentsize;
  secs.push({ name: u32(o), type: u32(o + 4), addr: u32(o + 12), off: u32(o + 16), size: u32(o + 20), link: u32(o + 24), entsize: u32(o + 36) });
}
const cstr = o => { let e = o; while (b[e]) e++; return b.toString('latin1', o, e); };
const shstr = secs[shstrndx];
secs.forEach(s => s.nm = cstr(shstr.off + s.name));
const byName = n => secs.find(s => s.nm === n);

function readSyms(sec) {
  if (!sec) return [];
  const str = secs[sec.link], out = [];
  for (let o = sec.off; o < sec.off + sec.size; o += 16) {
    out.push({ name: cstr(str.off + u32(o)), value: u32(o + 4), size: u32(o + 8), info: b[o + 12], shndx: u16(o + 14) });
  }
  return out;
}
const syms = [...readSyms(byName('.symtab')), ...readSyms(byName('.dynsym'))].filter(s => s.name);
// PLT stubs -> import names (ARM: 20-byte header, 12-byte entries in .rel.plt order)
{
  const plt = byName('.plt'), rel = byName('.rel.plt'), dyn = readSyms(byName('.dynsym'));
  if (plt && rel) {
    let i = 0;
    for (let o = rel.off; o < rel.off + rel.size; o += 8, i++) {
      const s = dyn[u32(o + 4) >> 8];
      if (s) syms.push({ name: s.name + '@plt', value: plt.addr + 20 + i * 12, size: 12, shndx: 1 });
    }
  }
}
const vaddrToOff = va => {
  const s = secs.find(s => s.addr && va >= s.addr && va < s.addr + s.size && s.type !== 8);
  return s ? s.off + (va - s.addr) : null;
};

if (cmd === 'secs') {
  secs.forEach(s => console.log(s.nm.padEnd(20), '0x' + s.addr.toString(16), 'off 0x' + s.off.toString(16), 'size 0x' + s.size.toString(16)));
} else if (cmd === 'syms') {
  const re = new RegExp(arg || '.');
  const seen = new Set();
  syms.filter(s => re.test(s.name)).forEach(s => { const k = s.name + s.value; if (seen.has(k)) return; seen.add(k);
    console.log('0x' + s.value.toString(16).padStart(8, '0'), String(s.size).padStart(6), s.shndx === 0 ? 'UND' : '   ', s.name); });
} else if (cmd === 'imports') {
  readSyms(byName('.dynsym')).filter(s => s.shndx === 0 && s.name).forEach(s => console.log(s.name));
} else if (cmd === 'dis') {
  await loadCapstone();
  let addr, name = arg;
  if (/^0x/.test(arg)) addr = parseInt(arg, 16);
  else { const s = syms.find(s => s.name === arg && s.value); if (!s) { console.log('no sym'); process.exit(1); } addr = s.value; }
  const thumb = addr & 1; addr &= ~1;
  const count = parseInt(arg2 || '80');
  const cs = new Capstone(Const.CS_ARCH_ARM, thumb ? Const.CS_MODE_THUMB : Const.CS_MODE_ARM);
  const off = vaddrToOff(addr);
  const insns = cs.disasm(b.subarray(off, off + count * 4), { address: addr });
  const symAt = new Map(syms.filter(s => s.value).map(s => [s.value & ~1, s.name]));
  for (const i of insns.slice(0, count)) {
    let extra = '';
    const m = /#0x([0-9a-f]+)$/.exec(i.opStr);
    if (/^(bl|blx|b)$/.test(i.mnemonic) && m) extra = symAt.get(parseInt(m[1], 16)) || '';
    const lit = /\[pc, #(-?0x[0-9a-f]+|-?\d+)\]/.exec(i.opStr);
    if (lit && i.mnemonic.startsWith('ldr')) { const la = i.address + 8 + parseInt(lit[1]); const lo = vaddrToOff(la); if (lo != null) extra = '=0x' + u32(lo).toString(16); }
    console.log('0x' + i.address.toString(16), (symAt.get(i.address) ? '<' + symAt.get(i.address) + '> ' : '') + i.mnemonic, i.opStr, extra ? '; ' + extra : '');
  }
  cs.close();
} else if (cmd === 'strref') {
  // find PIC references (ldr rX,[pc,#n]; add rX,pc,rX) to a string containing arg
  await loadCapstone();
  const ro = secs.filter(s => /rodata|\.data/.test(s.nm));
  const targets = [];
  for (const s of ro) { const txt = b.toString('latin1', s.off, s.off + s.size); let i = -1;
    while ((i = txt.indexOf(arg, i + 1)) >= 0) { let st = i; while (st > 0 && txt.charCodeAt(st - 1)) st--; targets.push(s.addr + st); } }
  const text = byName('.text');
  const cs = new Capstone(Const.CS_ARCH_ARM, Const.CS_MODE_ARM);
  const insns = [];
  for (let p = 0; p < text.size;) {
    const len = Math.min(4096, text.size - p);
    let got = [];
    try { got = cs.disasm(b.subarray(text.off + p, text.off + p + len), { address: text.addr + p }); } catch (e) { got = []; }
    insns.push(...got);
    const done = got.length ? (got[got.length - 1].address + 4 - text.addr) : p;
    p = done >= p + len ? p + len : done + 4;   // skip undecodable word
  }
  const regs = {};
  const funcs = syms.filter(s => s.value && s.size).sort((a, c) => a.value - c.value);
  const funcAt = a => { let f = null; for (const s of funcs) { if (s.value <= a && a < s.value + s.size) f = s; } return f ? f.name : '?'; };
  for (const i of insns) {
    let m = /^(r\d+|sl|fp|ip), \[pc, #(-?0x[0-9a-f]+|-?\d+)\]$/.exec(i.opStr);
    if (i.mnemonic === 'ldr' && m) { const lo = vaddrToOff(i.address + 8 + parseInt(m[2])); if (lo != null) { regs[m[1]] = u32(lo); if (targets.includes(u32(lo))) console.log('0x' + i.address.toString(16), funcAt(i.address), '-> (abs)', cstr(vaddrToOff(u32(lo)))); } continue; }
    m = /^(r\d+|sl|fp|ip), pc, (r\d+|sl|fp|ip)$/.exec(i.opStr);
    if (i.mnemonic === 'add' && m && regs[m[2]] != null) {
      const t = (i.address + 8 + regs[m[2]]) >>> 0;
      if (targets.includes(t)) console.log('0x' + i.address.toString(16), funcAt(i.address), '->', cstr(vaddrToOff(t)));
    }
  }
  cs.close();
} else if (cmd === 'grep') {
  // disassemble whole .text, print instructions whose text matches regex arg
  await loadCapstone();
  const text = byName('.text');
  const cs = new Capstone(Const.CS_ARCH_ARM, Const.CS_MODE_ARM);
  const funcs = syms.filter(s => s.value && s.size).sort((a, c) => a.value - c.value);
  const funcAt = a => { let f = null; for (const s of funcs) { if (s.value <= a && a < s.value + s.size) f = s; } return f ? f.name : '?'; };
  const re = new RegExp(arg);
  for (let p = 0; p < text.size;) {
    const len = Math.min(4096, text.size - p);
    let got = [];
    try { got = cs.disasm(b.subarray(text.off + p, text.off + p + len), { address: text.addr + p }); } catch (e) { got = []; }
    for (const i of got) { const t = i.mnemonic + ' ' + i.opStr; if (re.test(t)) console.log('0x' + i.address.toString(16), funcAt(i.address), t); }
    const done = got.length ? (got[got.length - 1].address + 4 - text.addr) : p;
    p = done >= p + len ? p + len : done + 4;
  }
  cs.close();
} else if (cmd === 'fstrings') {
  // list PIC/abs string references inside one function
  await loadCapstone();
  const s = syms.find(s => s.name === arg && s.value);
  const cs = new Capstone(Const.CS_ARCH_ARM, Const.CS_MODE_ARM);
  const off = vaddrToOff(s.value);
  const insns = cs.disasm(b.subarray(off, off + s.size), { address: s.value });
  const regs = {};
  const isStr = a => { const o = vaddrToOff(a); if (o == null) return null; const t = cstr(o); return /^[\x20-\x7e\t\n]{2,}$/.test(t) ? t : null; };
  for (const i of insns) {
    let m = /^(r\d+|sl|fp|ip), \[pc, #(-?0x[0-9a-f]+|-?\d+)\]$/.exec(i.opStr);
    if (i.mnemonic === 'ldr' && m) { const lo = vaddrToOff(i.address + 8 + parseInt(m[2])); if (lo != null) { regs[m[1]] = u32(lo); const t = isStr(u32(lo)); if (t) console.log('0x' + i.address.toString(16), JSON.stringify(t)); } continue; }
    m = /^(r\d+|sl|fp|ip), pc, (r\d+|sl|fp|ip)$/.exec(i.opStr);
    if (i.mnemonic === 'add' && m && regs[m[2]] != null) { const t = isStr((i.address + 8 + regs[m[2]]) >>> 0); if (t) console.log('0x' + i.address.toString(16), JSON.stringify(t)); }
  }
  cs.close();
} else if (cmd === 'rodata') {
  // print C string at vaddr
  console.log(cstr(vaddrToOff(parseInt(arg, 16))));
}
