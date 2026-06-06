"""voice_check: deterministic, stdlib-only voice profiling and draft checking.

Pipeline: corpus -> profile -> checks/rewrite -> report, with an eval harness
that proves the profile discriminates the user's writing from generic-AI text.
All analysis is offline and aggregate; LLM rewriting is delegated to the host
agent via the generated skill.
"""

__version__ = "0.1.0"
