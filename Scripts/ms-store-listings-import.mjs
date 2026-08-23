// Build the Partner Center "Import listings" CSV from an "Export listings" CSV.
//
// Why this exists: the legacy DevCenter submission API can no longer author submissions for Haven
// (see docs/STORE-AUTOPUBLISH.md, "The 2026-08 submission-API break"), so Store listings are bulk-
// edited through Partner Center's Export/Import listings feature instead. This script takes the
// exported en-us CSV and adds the eight localized columns (de, es, fr, it, ja, ko, pt-br, zh-cn),
// sourced from the same reviewed appstore-metadata.*.md files the API path used — plus it refreshes
// the en-us ReleaseNotes cell to the current whats_new.
//
// Usage:
//   Partner Center → draft submission → Store listings → "Export listings"  (a .csv download)
//   node Scripts/ms-store-listings-import.mjs ~/Downloads/listingData-*.csv
//   Partner Center → "Import listings" → upload the generated *.import.csv
//
// Screenshot cells are copied from the en-us column — Partner Center accepts its own dashboard
// image URLs across language columns, so every language shares the same screenshots. Features and
// screenshot captions have no per-locale source file; they are authored in the maps below with the
// same terminology as the reviewed translations. Update them if the en-us features change.
import { readFileSync, writeFileSync } from 'node:fs';
import { loadMetadata } from './lib/metadata.mjs';

const die = (m) => { console.error(m); process.exit(1); };

const SRC = process.argv[2] || die('usage: node Scripts/ms-store-listings-import.mjs <exported-listings.csv> [out.csv]');
const OUT = process.argv[3] || SRC.replace(/\.csv$/, '') + '.import.csv';
const ROOT = new URL('..', import.meta.url).pathname.replace(/\/$/, '');

function parseCsv(s) {
  if (s.charCodeAt(0) === 0xfeff) s = s.slice(1);
  const rows = []; let row = [], cell = '', q = false;
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (q) { if (c === '"') { if (s[i + 1] === '"') { cell += '"'; i++; } else q = false; } else cell += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(cell); cell = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && s[i + 1] === '\n') i++; row.push(cell); cell = ''; rows.push(row); row = []; }
    else cell += c;
  }
  if (cell.length || row.length) { row.push(cell); rows.push(row); }
  return rows;
}
const esc = (v) => /[",\n\r]/.test(v) ? '"' + v.replace(/"/g, '""') + '"' : v;

const LOCALES = [
  ['de', 'appstore-metadata.de-DE.md'],
  ['es', 'appstore-metadata.es-ES.md'],
  ['fr', 'appstore-metadata.fr-FR.md'],
  ['it', 'appstore-metadata.it.md'],
  ['ja', 'appstore-metadata.ja.md'],
  ['ko', 'appstore-metadata.ko.md'],
  ['pt-br', 'appstore-metadata.pt-BR.md'],
  ['zh-cn', 'appstore-metadata.zh-Hans.md'],
];

const FEATURES = {
  de: [
    'Ende-zu-Ende-verschlüsselt mit hybrider Post-Quanten-Kryptografie — nicht einmal wir können mitlesen',
    'Private Kreise nur auf Einladung — für Familie und enge Freunde',
    'Fotos, Videos und verschwindende Storys mit moderner Kamera',
    'Gruppen-Sprach- und Videoanrufe mit Bildschirmfreigabe — Peer-to-Peer',
    'Kein Konto, keine Telefonnummer, keine E-Mail — deine Identität bleibt auf deinem Gerät',
  ],
  es: [
    'Cifrado de extremo a extremo con criptografía poscuántica híbrida — ni nosotros podemos leerlo',
    'Círculos privados solo con invitación para familia y amigos cercanos',
    'Fotos, vídeos e historias efímeras con una cámara moderna',
    'Llamadas y videollamadas en grupo con pantalla compartida — peer-to-peer',
    'Sin cuenta, número de teléfono ni correo — tu identidad se queda en tu dispositivo',
  ],
  fr: [
    'Chiffré de bout en bout avec une cryptographie post-quantique hybride — même nous ne pouvons pas le lire',
    'Cercles privés sur invitation, pour la famille et les amis proches',
    'Photos, vidéos et stories éphémères avec un appareil photo moderne',
    "Appels audio et vidéo de groupe avec partage d'écran — pair-à-pair",
    'Pas de compte, de numéro de téléphone ni d’e-mail — votre identité reste sur votre appareil',
  ],
  it: [
    'Crittografia end-to-end con cifratura post-quantistica ibrida — nemmeno noi possiamo leggerla',
    'Cerchie private solo su invito per famiglia e amici stretti',
    'Foto, video e storie effimere con una fotocamera moderna',
    'Chiamate vocali e video di gruppo con condivisione dello schermo — peer-to-peer',
    'Nessun account, numero di telefono o email — la tua identità resta sul tuo dispositivo',
  ],
  ja: [
    'ハイブリッド耐量子暗号によるエンドツーエンド暗号化 — 開発者でさえ読めません',
    '招待制のプライベートサークル — 家族や親しい友達だけで',
    'モダンなカメラで写真・動画・消えるストーリーを共有',
    'グループ音声・ビデオ通話と画面共有 — ピアツーピア',
    'アカウント・電話番号・メール不要 — アイデンティティは端末の中に',
  ],
  ko: [
    '하이브리드 양자 내성 암호로 종단 간 암호화 — 개발자도 읽을 수 없습니다',
    '초대로만 들어오는 프라이빗 서클 — 가족과 가까운 친구를 위해',
    '모던 카메라로 사진, 동영상, 사라지는 스토리 공유',
    '화면 공유가 되는 그룹 음성·영상 통화 — P2P 직접 연결',
    '계정, 전화번호, 이메일 없음 — 내 정보는 내 기기에만',
  ],
  'pt-br': [
    'Criptografia de ponta a ponta com criptografia pós-quântica híbrida — nem nós podemos ler',
    'Círculos privados somente por convite, para família e amigos próximos',
    'Fotos, vídeos e stories que desaparecem, com uma câmera moderna',
    'Chamadas de voz e vídeo em grupo com compartilhamento de tela — peer-to-peer',
    'Sem conta, telefone ou e-mail — sua identidade fica no seu dispositivo',
  ],
  'zh-cn': [
    '端到端加密，采用混合抗量子密码学——连我们也无法读取',
    '仅限邀请的私密圈子，专为家人和挚友打造',
    '用现代相机拍摄照片、视频和阅后即焚的故事',
    '群组语音和视频通话，支持屏幕共享——点对点直连',
    '无需账号、手机号或邮箱——你的身份只留在你的设备上',
  ],
};

const CAPTIONS = {
  de: ['Feed-Tab auf einem Laptop', 'Tab „Nachrichten“ auf einem Laptop', 'Tab „Du“ auf einem Laptop'],
  es: ['Pestaña Feed en un portátil', 'Pestaña Mensajes en un portátil', 'Pestaña Tú en un portátil'],
  fr: ["L'onglet Feed sur un ordinateur portable", "L'onglet Messages sur un ordinateur portable", "L'onglet You sur un ordinateur portable"],
  it: ['Scheda Feed su un laptop', 'Scheda Messaggi su un laptop', 'Scheda Tu su un laptop'],
  ja: ['ノートPCのフィードタブ', 'ノートPCのメッセージタブ', 'ノートPCの「あなた」タブ'],
  ko: ['노트북의 피드 탭', '노트북의 메시지 탭', '노트북의 나 탭'],
  'pt-br': ['Aba Feed em um notebook', 'Aba Mensagens em um notebook', 'Aba Você em um notebook'],
  'zh-cn': ['笔记本电脑上的 Feed 标签页', '笔记本电脑上的消息标签页', '笔记本电脑上的“你”标签页'],
};

const rows = parseCsv(readFileSync(SRC, 'utf8'));
const hdr = rows[0];
const enIdx = hdr.indexOf('en-us');
if (enIdx < 0) throw new Error('en-us column not found');
const fieldRow = new Map(); // Field name -> row
for (const r of rows.slice(1)) if (r[0]) fieldRow.set(r[0], r);
const enCell = (f) => fieldRow.get(f)?.[enIdx] ?? '';

// per-locale metadata
const metas = {};
for (const [code, file] of LOCALES) metas[code] = await loadMetadata(`${ROOT}/${file}`);
const enMeta = await loadMetadata(`${ROOT}/appstore-metadata.md`);

// refresh en-us release notes to the current version, and hold every locale to the same version
const version = (enMeta.whats_new || '').match(/^\d+\.\d+\.\d+/)?.[0] || die('en whats_new does not start with a version');
fieldRow.get('ReleaseNotes')[enIdx] = enMeta.whats_new.slice(0, 1500);

const cap = (v, n) => (v && v.length > n ? v.slice(0, n) : v || '');
for (const [code] of LOCALES) {
  hdr.push(code);
  const col = hdr.length - 1;
  const m = metas[code];
  if (!m.whats_new?.startsWith(version)) die(`${code} whats_new does not start with ${version} — stale notes would ship`);
  const put = (field, val) => { const r = fieldRow.get(field); if (r) { while (r.length < col) r.push(''); r[col] = val ?? ''; } else if (val) console.log(`⚠ template has no row "${field}" — skipped for ${code}`); };
  put('Description', cap(m.description, 10000));
  put('ReleaseNotes', cap(m.whats_new, 1500));
  put('Title', m.name || 'Haven 〇');
  put('ShortTitle', 'Haven');
  put('ShortDescription', cap(m.promotional_text || m.subtitle, 200));
  put('DevStudio', enCell('DevStudio'));
  put('CopyrightTrademarkInformation', enCell('CopyrightTrademarkInformation'));
  put('OverrideLogosForWin10', 'False');
  for (let i = 1; i <= 3; i++) {
    put(`DesktopScreenshot${i}`, enCell(`DesktopScreenshot${i}`));
    put(`DesktopScreenshotCaption${i}`, CAPTIONS[code][i - 1]);
  }
  FEATURES[code].forEach((f, i) => { if (f.length > 200) throw new Error(`${code} Feature${i + 1} ${f.length} chars`); put(`Feature${i + 1}`, f); });
  const kws = (m.keywords || '').split(',').map((s) => s.trim()).filter((s) => s && s.length <= 30);
  let n = 0;
  for (const kw of kws) { if (n >= 7) break; if (!fieldRow.has(`SearchTerm${n + 1}`)) break; put(`SearchTerm${n + 1}`, kw); n++; }
}

// pad all rows to full width
const width = hdr.length;
for (const r of rows) while (r.length < width) r.push('');
const out = '﻿' + rows.map((r) => r.map(esc).join(',')).join('\r\n') + '\r\n';
writeFileSync(OUT, out);
console.log(`wrote ${OUT}: ${rows.length} rows × ${width} cols`);
for (const [code] of LOCALES) {
  const col = hdr.indexOf(code);
  const filled = rows.slice(1).filter((r) => r[col] && r[col].trim());
  console.log(`${code}: ${filled.length} filled — desc(${fieldRow.get('Description')[col].length}) notes(${fieldRow.get('ReleaseNotes')[col].length}) short(${fieldRow.get('ShortDescription')[col].length})`);
}
console.log(`en-us ReleaseNotes now: ${fieldRow.get('ReleaseNotes')[enIdx].slice(0, 60)}…`);
