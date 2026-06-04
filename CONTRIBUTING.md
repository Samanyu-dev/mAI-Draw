# Contributing to mAI-Draw

Thanks for helping improve mAI-Draw. This project is early-stage, so clear issues, small pull requests, and setup improvements are especially valuable.

## How to Contribute

1. Check existing issues before opening a new one.
2. For bugs, include expected behavior, actual behavior, and reproduction steps.
3. For features, describe the workflow and why it helps users.
4. Keep pull requests focused on one change.
5. Do not commit API keys, tokens, private URLs, or local configuration files.

## Local Setup

Use Xcode 16 or newer and configure secrets locally through Xcode scheme environment variables or ignored local build settings.

Required values for AI and sync features:

- `GEMINI_API_KEY`
- `OPENAI_API_KEY`
- `SUPABASE_URL`
- `SUPABASE_KEY`

The project should still compile without committing any real secret.

## Pull Request Checklist

- The change has a clear description.
- Secrets and local config files were not committed.
- Security-sensitive changes explain the risk and mitigation.
- UI changes include a screenshot or short screen recording when possible.
- Documentation was updated when behavior changed.

## Maintainer Tasks

The maintainer workflow includes issue triage, pull request review, release notes, documentation updates, and periodic security review of auth, sync, dependencies, and API usage.
