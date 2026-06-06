"""Default phrase lists used across profiling, checking, and rewriting.

All entries are lowercase. These are *defaults* — a user's profile can extend
them, but the deterministic core ships with sensible English lists so the tool
works out of the box with no configuration.

Lists are deliberately conservative for anything the rewriter will *remove* or
*replace*, to avoid mangling legitimate text. Detection lists (FILLER, HEDGES)
can be broader because flagging is non-destructive.
"""

from __future__ import annotations

# ---------------------------------------------------------------------------
# Spoken filler — disfluencies that belong in speech but not polished writing.
# Multi-word and unambiguous single words only; risky words like "like"/"just"
# are intentionally excluded from the default strip set.
# ---------------------------------------------------------------------------
FILLER: frozenset[str] = frozenset(
    {
        "you know",
        "i mean",
        "you see",
        "kind of",
        "sort of",
        "kinda",
        "sorta",
        "basically",
        "actually",
        "literally",
        "honestly",
        "pretty much",
        "i guess",
        "i suppose",
        "or whatever",
        "and stuff",
        "you know what i mean",
        "at the end of the day",
    }
)

# Phrases that signal hedging / lack of conviction.
HEDGES: frozenset[str] = frozenset(
    {
        "i think",
        "i believe",
        "i feel like",
        "maybe",
        "perhaps",
        "possibly",
        "somewhat",
        "arguably",
        "it seems",
        "more or less",
        "to some extent",
    }
)

# Corporate / business-speak. Flagged as soft violations.
CORPORATE: frozenset[str] = frozenset(
    {
        "leverage",
        "synergy",
        "synergies",
        "utilize",
        "utilise",
        "streamline",
        "robust",
        "seamless",
        "holistic",
        "paradigm",
        "bandwidth",
        "circle back",
        "low-hanging fruit",
        "move the needle",
        "value-add",
        "deep dive",
        "best-in-class",
        "mission-critical",
        "end-to-end",
        "touch base",
        "ideate",
        "operationalize",
        "drill down",
        "boil the ocean",
    }
)

# Generic-AI tells: words/phrases overrepresented in LLM prose.
AI_TELLS: frozenset[str] = frozenset(
    {
        "delve",
        "moreover",
        "furthermore",
        "in today's world",
        "it's worth noting",
        "it is worth noting",
        "it is important to note",
        "navigate the complexities",
        "tapestry",
        "testament to",
        "in conclusion",
        "dive into",
        "unlock",
        "elevate",
        "realm",
        "underscore",
        "pivotal",
        "multifaceted",
        "ever-evolving",
        "embark",
        "foster",
        "beacon",
        "treasure trove",
        "in the realm of",
        "plays a vital role",
        "a testament to",
    }
)

# Absolutes that often mark inflated / unsupported claims.
INFLATED: frozenset[str] = frozenset(
    {
        "world-class",
        "cutting-edge",
        "revolutionary",
        "game-changing",
        "best in the world",
        "unprecedented",
        "state-of-the-art",
        "next-generation",
        "industry-leading",
    }
)

# Corporate jargon -> plain replacement. Keys are safe to substitute verbatim.
# Must stay disjoint from AI_TELLS (see tests): these are word-for-word swaps,
# whereas AI tells usually need deletion or restructuring, not substitution.
CORPORATE_TO_PLAIN: dict[str, str] = {
    "utilize": "use",
    "utilise": "use",
    "leverage": "use",
    "commence": "start",
    "facilitate": "help",
    "streamline": "simplify",
    "endeavor": "try",
    "endeavour": "try",
    "ascertain": "find out",
    "operationalize": "run",
    "ideate": "brainstorm",
    "demonstrate": "show",
    "additional": "more",
    "numerous": "many",
    "prior to": "before",
    "subsequent to": "after",
    "in order to": "to",
    "circle back": "follow up",
    "robust": "solid",
    "move the needle": "make progress",
}

# Pure-filler AI phrases that can be deleted whole without breaking grammar.
SAFE_DELETE_AI: frozenset[str] = frozenset(
    {
        "it is worth noting that",
        "it's worth noting that",
        "it is important to note that",
        "in today's world",
        "in today's fast-paced world",
        "at the end of the day",
        "needless to say",
        "it goes without saying that",
    }
)

# Connector AI-tells safe to delete at a sentence start.
DELETABLE_CONNECTORS: frozenset[str] = frozenset(
    {"moreover", "furthermore", "additionally", "indeed", "notably"}
)

# Expanded form -> contraction, for the contraction-rate policy and rewriter.
EXPAND_TO_CONTRACTION: dict[str, str] = {
    "do not": "don't",
    "does not": "doesn't",
    "did not": "didn't",
    "is not": "isn't",
    "are not": "aren't",
    "was not": "wasn't",
    "were not": "weren't",
    "cannot": "can't",
    "can not": "can't",
    "will not": "won't",
    "would not": "wouldn't",
    "could not": "couldn't",
    "should not": "shouldn't",
    "have not": "haven't",
    "has not": "hasn't",
    "had not": "hadn't",
    "it is": "it's",
    "i am": "i'm",
    "you are": "you're",
    "we are": "we're",
    "they are": "they're",
    "that is": "that's",
    "there is": "there's",
    "what is": "what's",
    "who is": "who's",
    "i will": "i'll",
    "you will": "you'll",
    "we will": "we'll",
    "i have": "i've",
    "we have": "we've",
    "you have": "you've",
    "let us": "let's",
}

# Common English stopwords for n-gram filtering (kept small + stdlib-only).
STOPWORDS: frozenset[str] = frozenset(
    """a an and are as at be been being but by for from had has have he her his
    i if in into is it its me my no not of on or our she so that the their them
    they this to up us was we were what when which who will with you your he's
    it's i'm we're they're that's there's to be do does did done can could would
    should may might must about over under then than them""".split()
)
