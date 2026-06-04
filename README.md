# mAI-Draw

mAI-Draw is an open source iOS and iPadOS canvas app for AI-assisted visual thinking. It combines a whiteboard-style workspace with notes, sketches, imported media, audio transcription, authentication, sync, and AI-assisted text workflows.

The project is early-stage and public by design: the goal is to provide a useful SwiftUI reference implementation for creative AI tools on Apple platforms.

## What It Does

- Infinite-style canvas for visual notes and sketches
- Text blocks, post-it style notes, drawings, audio, and imported images
- AI-assisted illustration and text review workflows
- Audio transcription support
- Supabase authentication and project sync
- Separate iPad and iPhone targets

## Why Open Source

Creative AI apps often combine sensitive user content, external AI APIs, authentication, local storage, and sync. mAI-Draw is intended to become a transparent reference for building those workflows with safer defaults, public review, and contributor-friendly documentation.

## Project Status

This repository is newly public and under active development. The current focus is:

- Make setup reproducible for contributors
- Add CI checks and security scanning
- Document architecture and data flow
- Improve privacy and secret-handling practices
- Prepare the first contributor-friendly release

See [ROADMAP.md](ROADMAP.md) for planned work.

## Requirements

- macOS with Xcode 16 or newer
- iOS 17 or newer
- Swift 5.9
- A Supabase project for authentication and sync
- API keys for the AI features you want to enable

## Getting Started

1. Clone the repository.

   ```bash
   git clone https://github.com/dipaulavs/mAI-Draw.git
   cd mAI-Draw
   ```

2. Open the Xcode project.

   ```bash
   open IllustratorApp.xcodeproj
   ```

3. Select a target:

   - `IllustratorApp` for iPad
   - `mAIDrawPhone` for iPhone

4. Configure local secrets. Do not commit secrets to Git.

   The app reads these values from the app bundle or process environment:

   - `GEMINI_API_KEY`
   - `OPENAI_API_KEY`
   - `SUPABASE_URL`
   - `SUPABASE_KEY`

   For local development, set them in your Xcode scheme environment variables or inject them through local build settings that are ignored by Git.

5. Build and run from Xcode.

## Security

Do not open public issues for vulnerabilities or leaked credentials. See [SECURITY.md](SECURITY.md) for the reporting process.

This repository includes a GitHub Actions secret scan workflow to help catch accidental credential commits.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) before opening issues or pull requests.

Good first areas:

- Documentation improvements
- Reproducible local setup
- UI polish for iPhone and iPad layouts
- Tests and CI improvements
- Privacy and security hardening

## License

mAI-Draw is released under the MIT License. See [LICENSE](LICENSE).
