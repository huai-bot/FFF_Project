# Personal cloud-build bootstrap

This directory makes the original Windows player reproducible on a standard
GitHub-hosted `windows-2025-vs2026` runner. It does not change sponsorship checks.

## Public probe

Run **Public original build probe** manually from the Actions tab. It:

1. Uses the upstream .NET 11 targets and Visual Studio 2026 / v145.
2. Builds a pinned LakeUI revision as a neighboring checkout.
3. Prepares pinned FFmpeg, LibRaw, subtitle/disc and IAMF dependencies.
4. Builds the original player and its regression harness in Release mode.
5. Runs the first-frame event parsing regression and writes an executable hash.

No player executable is uploaded, no release is created, and no automatic
push/pull-request trigger is configured. Only prepared third-party dependencies
are cached, not player executables. Cache entries are repository-scoped.

## Usage and license boundaries

- This repository's own code is MIT; preserve the original notices.
- LakeUI's public source is GPL-3.0-only unless separately licensed. The original
  developer's commercial agreement is not granted to forks.
- This bootstrap selects an LGPL FFmpeg build, not the original developer's
  custom GPL/nonfree runtime. Some optional codecs/filters can therefore differ.
- Do not upload a private personalization modification to this public fork.
- Copy the tested source into an independent private repository before making
  private-only changes. GitHub caches and previous runs do not migrate with Git.
- Private Windows runs use the account's private Actions allowance; concurrency
  is deliberately limited to two workers. Review account budgets before running.

The source of truth for each dependency revision, archive digest, and validation
is the associated PowerShell script. A green build verifies compilation and the
listed regression, not every audio/video format or interactive GUI feature.
