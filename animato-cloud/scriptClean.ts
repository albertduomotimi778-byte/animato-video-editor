/**
 * Pasted scripts often carry production notes that must never be read aloud or shown to the creator:
 * a title line, "Duration: 120 seconds | Genre: Drama", "SCENE 1: SEVEN YEARS OF PAIN (0:00–0:25)",
 * time stamps, SRT numbers, "CUT TO:", "THE END." and so on. This keeps only what is meant to be said.
 *
 *   'story' – narration scripts (stories, kids): also drops "Narrator:" labels, Setting/Music/Camera notes and #-headings.
 *   'light' – scripts with speaker labels or [Verse]/[Chorus] markers (podcasts, lyrics, dialogue): only the
 *             time stamps, scene headings, metadata lines, transitions and SRT numbering go.
 *
 * Kept identical in server/scriptClean.ts and animato-cloud/scriptClean.ts (the runner cannot import the server).
 */
const TIME = String.raw`\d{1,2}:\d{2}(?::\d{2})?(?:[.,]\d{1,3})?`;
const RANGE = new RegExp(String.raw`[\[(]?\s*${TIME}\s*(?:-->|[-–—]|to)\s*${TIME}\s*[\])]?`, 'gi');
const STAMP = new RegExp(String.raw`[\[(]\s*${TIME}\s*[\])]`, 'g');
const HAS_TIME = new RegExp(String.raw`[\[(]?\s*${TIME}\s*[\])]?`);
const NUM_WORD = 'one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|[ivx]{1,4}|\\d{1,3}[a-z]?';
const HEADING = new RegExp(String.raw`^[\s#*_=~>-]*(?:scene|sc|act|chapter|part|shot|segment|section|sequence|episode|take|stanza)\.?\s*(?:#|no\.?|number)?\s*(?:${NUM_WORD})\b(.*)$`, 'i');
const SLUG = /^[\s#*_-]*(?:int|ext|int\.?\/ext|ext\.?\/int|i\/e)[.\s].*$/i;
const TRANSITION = /^[\s#*_=~>-]*(?:cut to|fade (?:in|out|to)|dissolve to|smash cut|match cut|back to|flashback|end of (?:scene|episode|story|video|act)|the end|fin|to be continued|continued|montage|b-?roll)\b[^a-z]*$/i;
const META_ALL = /^[\s#*_-]*(?:duration|runtime|run time|genre|length|title|written by|author|writer|director|logline|synopsis|word count|target audience|format|aspect ratio)\s*[:：]\s*.*$/i;
const META_STORY = /^[\s#*_-]*(?:setting|location|time|characters?|cast|tone|mood|style|language|theme|music|sfx|sound|camera|visuals?|transition|notes?|scene description)\s*[:：]\s*.*$/i;
const NARRATOR = /^[\s*_-]*(?:narrator|narration|voice[- ]?over|v\.?o\.?)\s*(?:\([^)]*\))?\s*[:：-]\s*/i;
const DIRECTION_WORDS = String.raw`(?:sound|sfx|music|song|audio|cut|fade|camera|pan|zoom|close[- ]?up|wide shot|transition|montage|b-?roll|scene|title card|text on screen|on[- ]screen|visual|overlay|music fades?|music (?:swells|plays|ends|begins))`;
const BRACKET_DIRECTION_LINE = new RegExp(String.raw`^\s*[\[(]\s*${DIRECTION_WORDS}\b[^\])]*[\])]\s*$`, 'i');
const BRACKET_DIRECTION_INLINE = new RegExp(String.raw`[\[(]\s*${DIRECTION_WORDS}\b[^\])]{0,80}[\])]`, 'gi');

const words = (s: string) => s.split(/\s+/).filter(Boolean).length;

export function stripScriptDirections(raw: string, mode: 'story' | 'light' = 'story'): string {
  const original = String(raw ?? '');
  const story = mode === 'story';
  const lines = original.replace(/\r\n?/g, '\n').replace(/[\u200B-\u200D\uFEFF]/g, '').split('\n');
  const meta = (l: string) => META_ALL.test(l) || (story && META_STORY.test(l) && words(l) <= 16);
  // A title line: the first line, written in capitals with no sentence punctuation, above notes or scene headings.
  const firstIdx = lines.findIndex((l) => l.trim());
  const isCapsTitle = (l: string) => /\p{L}/u.test(l) && l === l.toUpperCase() && l.trim().length <= 90 && !/[.!?…]["”']?\s*$/.test(l.trim()) && words(l) <= 14 && !HEADING.test(l);
  const rest = lines.slice(firstIdx + 1, firstIdx + 8);
  const dropTitle = firstIdx >= 0 && isCapsTitle(lines[firstIdx]) && rest.some((l) => meta(l) || HEADING.test(l) || /^[\s#*_-]*$/.test(l) === false && TRANSITION.test(l));
  const out: string[] = [];
  lines.forEach((line, i) => {
    let l = line;
    if (dropTitle && i === firstIdx) return;
    if (/-->/.test(l) && new RegExp(TIME).test(l)) return;                 // SRT time line
    if (/^\s*\d{1,4}\s*$/.test(l)) return;                                 // SRT / list numbering on its own line
    if (HEADING.test(l) && words(l) <= 16) {
      const tail = (l.match(HEADING)?.[1] || '').trim();
      // "SCENE 1", "Scene 2: The cruel words (0:25–0:45)", "Part 3 – …" are headings; "Part of her wanted…" is not (the number is required above).
      if (!tail || /^[:.\-–—)(\[|]/.test(tail) || HAS_TIME.test(tail) || tail === tail.toUpperCase()) return;
    }
    if (SLUG.test(l) || TRANSITION.test(l) || meta(l)) return;
    if (BRACKET_DIRECTION_LINE.test(l)) return;
    if (story && /^\s*#{1,6}\s+/.test(l) && words(l) <= 10 && !/[.!?]\s*$/.test(l)) return;
    l = l.replace(RANGE, ' ').replace(STAMP, ' ');
    if (story) l = l.replace(NARRATOR, '').replace(BRACKET_DIRECTION_INLINE, ' ');
    l = l.replace(/[ \t]{2,}/g, ' ').trim();
    if (/^[\s|•·*_=~-]*$/.test(l)) { out.push(''); return; }
    out.push(l);
  });
  const cleaned = out.join('\n').replace(/\n{3,}/g, '\n\n').trim();
  // Never hand back an empty script: if everything looked like a direction, the person's text stays as it was.
  return words(cleaned) >= 3 ? cleaned : original.trim();
}
