"""Exercise model selection and effort validation without calling a provider."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = str(Path(sys.argv[1]).resolve())
root = Path(__file__).resolve().parent.parent

with tempfile.TemporaryDirectory(prefix="ai-reviewer-models-") as temporary:
    home = Path(temporary)
    config = json.loads((root / "config/local.example.json").read_text())
    config["repoPath"] = str(root)
    config["codexHome"] = str(home)
    config_path = home / "config.json"
    config_path.write_text(json.dumps(config))

    def run(*arguments, succeeds=True):
        result = subprocess.run(
            [binary, "models", "--config", str(config_path), *arguments],
            capture_output=True, text=True,
        )
        assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
        return result.stdout + result.stderr

    listing = run("list", "codex")
    assert "gpt-6.1-sol\tdefault=low\t" in listing, listing
    for model in ("gpt-6.1-sol", "gpt-6-astra", "gpt-6-sol", "gpt-6-luna"):
        assert model + "\t" in listing, listing
        run("set", model, "--effort", "medium")
        selection = json.loads(config_path.read_text())["instructionSet"]["engineModels"]["codex"]
        assert selection["defaultModel"] == model
        assert selection["defaultReasoningEffort"] == "medium"
        before = config_path.read_bytes()
        run("set", model, "--effort", "ultra", succeeds=False)
        assert config_path.read_bytes() == before

    # The cached catalogue must remain authoritative, including effort defaults.
    (home / "models_cache.json").write_text(json.dumps({"models": [{
        "slug": "gpt-6.1-sol", "visibility": "list", "supported_in_api": True,
        "default_reasoning_level": "low",
        "supported_reasoning_levels": [{"effort": effort} for effort in ("low", "medium", "ultra")],
    }]}))
    assert run("list", "codex").strip() == "gpt-6.1-sol\tdefault=low\tefforts=low,medium"
    run("set", "gpt-6.1-sol", "--effort", "medium")
    before = config_path.read_bytes()
    run("set", "gpt-6.1-sol", "--effort", "max", succeeds=False)
    run("set", "gpt-6-luna", "--effort", "medium", succeeds=False)
    assert config_path.read_bytes() == before

print("Model selection checks passed (fallback, cache, effort validation, atomic rejection).")
