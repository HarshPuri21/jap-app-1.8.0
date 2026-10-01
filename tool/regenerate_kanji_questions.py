#!/usr/bin/env python3
"""Regenerate assets/data/kanji_questions.json from assets/data/kanji.json.

This is the repeatable half of the kanji dataset pipeline (see
merge_kanji_dataset.py for the one-time old+new merge). Re-run this any time
kanji.json changes, so kanji_questions.json stays in sync with it.

difficulty is derived from jlpt_level (N5/N4 -> easy, N3 -> normal,
N2/N1 -> hard). For entries with no jlpt_level, this falls back to whatever
the *previous* kanji_questions.json had for that same kanji (so re-running
this script doesn't silently reshuffle difficulty for kanji the JLPT dataset
has no opinion on); a brand-new kanji with neither a level nor a prior
entry defaults to 'normal'.

options/answer: answer = meaning; options = answer + 3 other distinct
meanings drawn at random from the rest of the dataset, deduped, shuffled.
Matches the existing file's observed pattern (verified against samples of
the pre-merge file before this script was written).

Usage:
    python3 tool/regenerate_kanji_questions.py
"""

from __future__ import annotations

import json
import random
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
KANJI_JSON = ROOT / "assets" / "data" / "kanji.json"
KANJI_QUESTIONS_JSON = ROOT / "assets" / "data" / "kanji_questions.json"

# Fixed seed: deterministic output across re-runs (only actually changes
# when the underlying kanji.json changes), so diffs stay reviewable instead
# of churning every distractor on every regeneration.
RANDOM_SEED = 20260926

LEVEL_TO_DIFFICULTY = {
    "N5": "easy",
    "N4": "easy",
    "N3": "normal",
    "N2": "hard",
    "N1": "hard",
}


def load_json(path: Path):
    with path.open(encoding="utf-8") as f:
        return json.load(f)


def main() -> None:
    kanji_entries = load_json(KANJI_JSON)

    # Old kanji_questions.json is only consulted for its difficulty field,
    # as a fallback for jlpt_level=null entries -- read it BEFORE
    # overwriting the file below.
    old_difficulty_by_char: dict[str, str] = {}
    if KANJI_QUESTIONS_JSON.exists():
        for e in load_json(KANJI_QUESTIONS_JSON):
            old_difficulty_by_char[e["kanji"]] = e["difficulty"]

    rng = random.Random(RANDOM_SEED)

    # Pool of (kanji, meaning) for distractor selection -- skip blank
    # meanings so an empty-string option can never appear in a quiz.
    meaning_pool = [(e["kanji"], e["meaning"]) for e in kanji_entries if e["meaning"]]

    questions = []
    difficulty_counts: dict[str, int] = {"easy": 0, "normal": 0, "hard": 0}

    for e in kanji_entries:
        char = e["kanji"]
        level = e.get("jlpt_level")
        if level in LEVEL_TO_DIFFICULTY:
            difficulty = LEVEL_TO_DIFFICULTY[level]
        elif char in old_difficulty_by_char:
            difficulty = old_difficulty_by_char[char]
        else:
            difficulty = "normal"
        difficulty_counts[difficulty] += 1

        answer = e["meaning"]
        # Distinct-meaning distractors, drawn from every OTHER kanji's
        # meaning (never this kanji's own, never a duplicate of the answer
        # or of each other).
        candidates = [m for k, m in meaning_pool if k != char and m != answer]
        rng.shuffle(candidates)
        distractors: list[str] = []
        seen = {answer}
        for m in candidates:
            if m in seen:
                continue
            seen.add(m)
            distractors.append(m)
            if len(distractors) == 3:
                break
        options = [answer, *distractors]
        rng.shuffle(options)

        questions.append({
            "kanji": char,
            "meaning": e["meaning"],
            "onyomi": e["onyomi"],
            "kunyomi": e["kunyomi"],
            "breakdown": e["breakdown"],
            "common_words": e["common_words"],
            "is_radical": e["is_radical"],
            "difficulty": difficulty,
            "options": options,
            "answer": answer,
            "jlpt_level": level,
        })

    with KANJI_QUESTIONS_JSON.open("w", encoding="utf-8") as f:
        json.dump(questions, f, ensure_ascii=False, indent=2)
        f.write("\n")

    print(f"Regenerated {len(questions)} kanji_questions.json entries")
    print(f"Difficulty distribution: {difficulty_counts}")
    short_option_entries = [q["kanji"] for q in questions if len(q["options"]) < 4]
    if short_option_entries:
        print(f"WARNING: {len(short_option_entries)} entries have <4 options "
              f"(meaning pool too small / too many duplicate meanings): "
              f"{short_option_entries[:20]}")
    else:
        print("Every entry has exactly 4 options.")


if __name__ == "__main__":
    main()
