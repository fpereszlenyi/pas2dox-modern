# Publishing the prepared candidate

Local preparation does not publish to GitHub. No account/maintainer identity is
embedded in the repository.

1. Review the source, licenses, README, release notes and validation.
2. Create a repository named `pas2dox-modern` under the intended GitHub account.
3. Commit the prepared source on `main` with the intended author identity, add
   the repository as `origin` and push. `build/` is ignored.
4. Tag the reviewed commit `v0.60.0-rc4`.
5. Create a draft **pre-release**; use `RELEASE_NOTES.md` as its body.
6. Attach both ZIPs and `SHA256SUMS.txt`, review the draft, then publish.

GitHub's automatic source archive follows the tagged commit. The explicit source
ZIP is an additional artifact; the Windows ZIP also contains all corresponding
source and build instructions for its exact executable.

For future versions, update `source/pas2dox.dpr` and the release documents together.
Build with licensed Delphi, run all tests and inspect example graphs/TODOs.
Keep confidential application files and generated manuals out of artifacts.
Do not assume GitHub-hosted runners include Delphi. Preserve upstream notices.

Current archives have per-file `MANIFEST.sha256` lists. Preparation-only tools
and packaging reports remain outside the repository.
