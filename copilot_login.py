"""Run the GitHub Copilot device-code flow once and cache the credentials.

This runs inside a throwaway LiteLLM container with the token directory bind
mounted, so the credentials land on the host and every later container reuses
them. LiteLLM would otherwise do this lazily on the first model request, where
the device code goes into the gateway log and the poll window is 60 seconds.
"""

import sys

from litellm.llms.github_copilot.authenticator import Authenticator


def main() -> int:
    try:
        Authenticator().get_api_key()
    except Exception as exc:  # noqa: BLE001 - surface whatever the flow raised
        print(f"Copilot authentication failed: {exc}", file=sys.stderr)
        return 1
    print("Copilot credentials cached in ~/.config/litellm/github_copilot")
    return 0


if __name__ == "__main__":
    sys.exit(main())
