# Security Policy

## Supported Versions

mAI-Draw is early-stage. Security fixes are currently handled on the default branch and included in the next public release.

## Reporting a Vulnerability

Please do not report vulnerabilities, leaked credentials, or private security details in public issues.

To report a vulnerability, open a private GitHub security advisory for this repository when available, or contact the maintainer directly through GitHub.

Please include:

- A short summary of the issue
- Affected files or workflows
- Steps to reproduce when safe to share
- Potential impact
- Suggested fix, if known

## Security Focus Areas

The project prioritizes review in these areas:

- Hardcoded secrets and API key handling
- Supabase authentication and sync behavior
- User-generated content and local file handling
- Audio recording and transcription privacy
- Dependency and build workflow security

## Maintainer Workflow

Security-related pull requests should be small, easy to review, and avoid logging or exposing sensitive values. When possible, include a regression test or a clear manual verification note.
