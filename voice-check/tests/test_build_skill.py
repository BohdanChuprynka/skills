import tempfile
import unittest
from pathlib import Path

from voice_check import corpus, profile, skill_template


def rec(text, kind):
    return corpus.Record("i", "p", text, kind, None, {})


def _profile_dir(tmp: Path) -> Path:
    recs = [rec("Quick note. It works. Ping me. Tell me if it breaks.", "polished_writing")]
    out = tmp / "profiles"
    profile.write_profile(profile.build_profile(recs), out)
    return out


class SkillTemplateTests(unittest.TestCase):
    def test_render_has_frontmatter_and_modes(self):
        rules = profile.to_voice_rules(profile.build_profile([rec("Hi. Ship it.", "polished_writing")]))
        md = skill_template.render_skill(rules, "PROFILE BODY")
        self.assertIn("name: voice-check", md)
        self.assertIn("description:", md)
        self.assertIn("Audit", md)
        self.assertIn("Rewrite", md)

    def test_render_has_no_unfilled_placeholders(self):
        rules = profile.to_voice_rules(profile.build_profile([rec("Hi. Ship it.", "polished_writing")]))
        md = skill_template.render_skill(rules, "body")
        self.assertNotIn("{{", md)
        self.assertNotIn("}}", md)

    def test_render_embeds_hard_no_list(self):
        rules = profile.to_voice_rules(profile.build_profile([rec("Hi. Ship it.", "polished_writing")]))
        md = skill_template.render_skill(rules, "body")
        self.assertIn("leverage", md)  # a corporate word from the hard-no list
        self.assertIn("delve", md)  # an AI tell

    def test_write_skill_emits_claude_and_codex(self):
        tmp = Path(tempfile.mkdtemp())
        prof = _profile_dir(tmp)
        out = tmp / "skills" / "voice-check"
        paths = skill_template.write_skill(prof, out, targets=("claude", "codex"))
        self.assertTrue((out / "SKILL.md").exists())
        self.assertTrue(any("codex" in str(p).lower() for p in paths))


if __name__ == "__main__":
    unittest.main()
