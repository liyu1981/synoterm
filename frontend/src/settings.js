/**
 * Terminal appearance settings: font family, size and line height.
 *
 * Precedence: URL parameters (one-off, not saved) > localStorage (saved in the
 * settings panel) > built-in defaults. Everything is validated and clamped, so
 * a bad value cannot make the terminal unreadable or unusable.
 */

const STORAGE_KEY = "synoterm.settings.v1";

export const FONT_STACK =
  '"JetBrains Mono", "Fira Code", "SFMono-Regular", Menlo, Consolas, "DejaVu Sans Mono", "Liberation Mono", monospace';

export const DEFAULTS = {
  fontFamily: FONT_STACK,
  fontSize: 13,
  lineHeight: 1.15,
};

export const LIMITS = {
  fontSize: { min: 8, max: 32 },
  lineHeight: { min: 1.0, max: 2.5 },
  fontFamilyLength: 200,
};

/** Common monospace families offered in the panel (all local — no downloads). */
export const FONT_CHOICES = [
  "JetBrains Mono",
  "Fira Code",
  "Cascadia Mono",
  "Source Code Pro",
  "IBM Plex Mono",
  "Hack",
  "Inconsolata",
  "Menlo",
  "Monaco",
  "Consolas",
  "DejaVu Sans Mono",
  "Liberation Mono",
  "Courier New",
  "monospace",
];

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

export function sanitizeFontFamily(value) {
  if (typeof value !== "string") return DEFAULTS.fontFamily;
  // Strip control characters and the CSS-breaking characters we never need.
  const cleaned = value
    .replace(/[\u0000-\u001f\u007f]/g, " ")
    .replace(/[;{}<>]/g, "")
    .trim()
    .slice(0, LIMITS.fontFamilyLength);
  return cleaned.length > 0 ? cleaned : DEFAULTS.fontFamily;
}

export function sanitizeFontSize(value) {
  const size = Number(value);
  if (!Number.isFinite(size)) return DEFAULTS.fontSize;
  return Math.round(clamp(size, LIMITS.fontSize.min, LIMITS.fontSize.max));
}

export function sanitizeLineHeight(value) {
  const height = Number(value);
  if (!Number.isFinite(height)) return DEFAULTS.lineHeight;
  return Math.round(clamp(height, LIMITS.lineHeight.min, LIMITS.lineHeight.max) * 100) / 100;
}

/** Plain-text CSS family list, e.g. `"Fira Code", monospace`. */
export function cssFontFamily(family) {
  const cleaned = sanitizeFontFamily(family);
  // A bare name with spaces must be quoted; keep existing quotes/commas as-is.
  if (/["',]/.test(cleaned)) return cleaned;
  return /\s/.test(cleaned) ? `"${cleaned}", monospace` : `${cleaned}, monospace`;
}

function normalize(input) {
  const source = input && typeof input === "object" ? input : {};
  return {
    fontFamily: sanitizeFontFamily(source.fontFamily),
    fontSize: sanitizeFontSize(source.fontSize),
    lineHeight: sanitizeLineHeight(source.lineHeight),
  };
}

function fromUrl() {
  const params = new URLSearchParams(window.location.search);
  const overlay = {};
  const family = params.get("fontFamily") || params.get("font");
  const size = params.get("fontSize");
  const height = params.get("lineHeight");
  if (family) overlay.fontFamily = family;
  if (size) overlay.fontSize = size;
  if (height) overlay.lineHeight = height;
  return overlay;
}

function fromStorage() {
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch {
    return {};
  }
}

export function loadSettings() {
  return normalize({ ...DEFAULTS, ...fromStorage(), ...fromUrl() });
}

export function saveSettings(patch) {
  const settings = normalize({ ...loadSettings(), ...patch });
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(settings));
  } catch {
    /* private mode / storage full: keep the in-memory value */
  }
  return settings;
}

export function resetSettings() {
  try {
    window.localStorage.removeItem(STORAGE_KEY);
  } catch {
    /* ignore */
  }
  return normalize(DEFAULTS);
}
