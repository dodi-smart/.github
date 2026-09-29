## [1.16.1](https://github.com/dodi-smart/.github/compare/v1.16.0...v1.16.1) (2026-09-29)

### 🐛 Bug Fixes

* **agents:** persist checkout credentials for triage and assist, which claude-code-action fetches with ([81ee518](https://github.com/dodi-smart/.github/commit/81ee5186b953417ecff81ba8e3b03e84d764199d))

## [1.16.0](https://github.com/dodi-smart/.github/compare/v1.15.2...v1.16.0) (2026-09-29)

### ✨ Features

* **pr-checks:** opt-in hk input that runs hk check --all and keeps the SARIF as an artifact ([1d1f354](https://github.com/dodi-smart/.github/commit/1d1f354e496be5903168e25e1bd08d025c929cd2))

## [1.15.2](https://github.com/dodi-smart/.github/compare/v1.15.1...v1.15.2) (2026-09-29)

### 🐛 Bug Fixes

* **checkout:** stop sparse checkouts on persistent workspaces and heal the ones left behind ([#94](https://github.com/dodi-smart/.github/issues/94)) ([8f726fe](https://github.com/dodi-smart/.github/commit/8f726fe74411ffc62fcae8e4d92eb367320bbdf8))

## [1.15.1](https://github.com/dodi-smart/.github/compare/v1.15.0...v1.15.1) (2026-09-29)

### 🐛 Bug Fixes

* **pr-checks:** run commitlint as a CLI on the light runner, not a Docker action ([915e794](https://github.com/dodi-smart/.github/commit/915e7947133e8a0e07845a94af7d40965d8be17f))

## [1.15.0](https://github.com/dodi-smart/.github/compare/v1.14.1...v1.15.0) (2026-09-29)

### ✨ Features

* **pr-checks:** default react-doctor-paths to web source and package.json ([0ac40fe](https://github.com/dodi-smart/.github/commit/0ac40feee7e4931de918f0acf9de2b953fc19151))
* **pr-checks:** zavet-audit and zavet-install inputs for the folded knowledge-layer job ([ae4dd29](https://github.com/dodi-smart/.github/commit/ae4dd2974239d194882cb29f5b61af8bdf9a1116))

## [1.14.1](https://github.com/dodi-smart/.github/compare/v1.14.0...v1.14.1) (2026-09-29)

### 🐛 Bug Fixes

* **ci:** drop persisted checkout credentials, scope publish-release writes and the picker jobs, and justify the App token uses ([f0eae60](https://github.com/dodi-smart/.github/commit/f0eae60e357e9bcf7263c28e6d81cd5df8c69978))
* **ci:** pass the action path through env and enforce zizmor at every severity ([4951ac0](https://github.com/dodi-smart/.github/commit/4951ac0436b5cc38e8257cfc81e882da2af46302))

## [1.14.0](https://github.com/dodi-smart/.github/compare/v1.13.3...v1.14.0) (2026-09-29)

### ✨ Features

* **pr-checks:** add `coverage: lcov` with a reporter that reads any LCOV file ([746bf88](https://github.com/dodi-smart/.github/commit/746bf88b5a84e65fe71ea10cf313c95db54801a8))

### 🐛 Bug Fixes

* **pr-checks:** post the coverage comment from a job that runs none of the caller's code ([7c54f69](https://github.com/dodi-smart/.github/commit/7c54f69edf9b9c342e8c1eebfaf6696595e5b6c1))

## [1.13.3](https://github.com/dodi-smart/.github/compare/v1.13.2...v1.13.3) (2026-09-29)

### ⚡ Performance Improvements

* **pr-checks:** fold zavet and react-doctor into pr-checks, run commitlint on the light pool ([#85](https://github.com/dodi-smart/.github/issues/85)) ([a3d6ffc](https://github.com/dodi-smart/.github/commit/a3d6ffcf519310757c9eb03977611e572a57752d)), closes [#46](https://github.com/dodi-smart/.github/issues/46)

## [1.13.2](https://github.com/dodi-smart/.github/compare/v1.13.1...v1.13.2) (2026-09-29)

### 🐛 Bug Fixes

* **agent-gate:** read live labels so a re-run cannot miss a late agent:no-touch ([a7cd305](https://github.com/dodi-smart/.github/commit/a7cd305a7a12f326d8c722120da88bca9c1b9d79))

## [1.13.1](https://github.com/dodi-smart/.github/compare/v1.13.0...v1.13.1) (2026-09-29)

### 🐛 Bug Fixes

* **deps-verify:** judge from the PR's current labels, not the event snapshot ([1c6d20c](https://github.com/dodi-smart/.github/commit/1c6d20c469d29192687ec894c1585dff1df2fd05))

## [1.13.0](https://github.com/dodi-smart/.github/compare/v1.12.3...v1.13.0) (2026-09-29)

### ✨ Features

* **changed-files:** add an all-matched output for skips that need every file to match ([93ef35f](https://github.com/dodi-smart/.github/commit/93ef35f4b120f7abb91b043b37bf08fda286b40d))
* **run-phases:** add an action that runs command phases with a timing table ([fd5dae0](https://github.com/dodi-smart/.github/commit/fd5dae02eeb6676bcd6ba6877561a342e4d6e18f))

### ⚡ Performance Improvements

* **pr-checks:** start build beside checks, drop the clones, run commands as timed phases ([cfd848a](https://github.com/dodi-smart/.github/commit/cfd848a09bcde4b83f90ef82cc44b186b794a782))

## [1.12.3](https://github.com/dodi-smart/.github/compare/v1.12.2...v1.12.3) (2026-09-29)

### ⚡ Performance Improvements

* **deps-verify:** wait for pr-checks on the light pool and skip the agent when nothing new is judged ([be8621a](https://github.com/dodi-smart/.github/commit/be8621ae669dd42c1a2fd8a14a3370317be99a33))

## [1.12.2](https://github.com/dodi-smart/.github/compare/v1.12.1...v1.12.2) (2026-09-29)

### ⚡ Performance Improvements

* **setup-stack:** cache Gradle and Kotlin/Native on self-hosted macOS ([dca11d6](https://github.com/dodi-smart/.github/commit/dca11d60724ff5a275ac40d6c1e7d1571577dc9f))

## [1.12.1](https://github.com/dodi-smart/.github/compare/v1.12.0...v1.12.1) (2026-09-29)

### ⚡ Performance Improvements

* **release:** add release-tooling, semantic-release installed in a private prefix from a lockfile ([33f0db3](https://github.com/dodi-smart/.github/commit/33f0db3e77e17a2185e1d724d05e01d74d48ddd1))
* **release:** use release-tooling and run the backmerge inside the release job ([a5fbc71](https://github.com/dodi-smart/.github/commit/a5fbc715cd6ada0e7f181aaf538578e9fe945358))

## [1.12.0](https://github.com/dodi-smart/.github/compare/v1.11.0...v1.12.0) (2026-09-29)

### ✨ Features

* **setup-stack:** build-env input, bun resolved from the repo, rust toolchain pinned by SHA ([1026a15](https://github.com/dodi-smart/.github/commit/1026a15669ffe0eadaa2480c721c6bec2a1476c6))

## [1.11.0](https://github.com/dodi-smart/.github/compare/v1.10.0...v1.11.0) (2026-09-29)

### ✨ Features

* add changed-files action ([37bb2ca](https://github.com/dodi-smart/.github/commit/37bb2ca70af77bac608483fa3e12e1c574970329))

### 🐛 Bug Fixes

* **supabase-deploy:** wait for the deployment of this commit before probing health routes ([0b49341](https://github.com/dodi-smart/.github/commit/0b4934105c4cf6f857aafcf01b78bd78fe40c302))

### ⚡ Performance Improvements

* **supabase-checks:** cache the local stack's images and read changed files through the API ([6aa7708](https://github.com/dodi-smart/.github/commit/6aa7708d3dfbcc0144fb5782dfc3ce834464e057))

## [1.10.0](https://github.com/dodi-smart/.github/compare/v1.9.0...v1.10.0) (2026-09-29)

### ✨ Features

* **pick-runner:** decide the fallback from one cached listing, and never send heavy to the light pool ([2b5e54f](https://github.com/dodi-smart/.github/commit/2b5e54f3636a62de948be749776f05cf7b23d0d1))

## [1.9.0](https://github.com/dodi-smart/.github/compare/v1.8.2...v1.9.0) (2026-09-29)

### ✨ Features

* **agent-gate:** classify the author once and add an event allow-list ([fb8cfe9](https://github.com/dodi-smart/.github/commit/fb8cfe9158b69acab960622a3d337b5da5b3e1ec))
* **sticky-comment:** add a delete mode that needs no body file ([255e536](https://github.com/dodi-smart/.github/commit/255e536505575fa15e3b1164c8f5cc530199c4c2))

### 🐛 Bug Fixes

* **deps-verify:** read allowed-bots from the gate's dependency-bots output ([f7a500d](https://github.com/dodi-smart/.github/commit/f7a500dafdf51520a753b4e146f783cda14e6750))
* **issue-triage:** stop a person's PR review before the triage agent ([650af65](https://github.com/dodi-smart/.github/commit/650af65f5287195387433b4563e671e6a9a01310))
* **zavet-check:** report-only for automation bots, and comment through sticky-comment ([2b75405](https://github.com/dodi-smart/.github/commit/2b75405250d27844df6d10466a93844fa7674f15))

## [1.8.2](https://github.com/dodi-smart/.github/compare/v1.8.1...v1.8.2) (2026-09-29)

### 🐛 Bug Fixes

* **renovate:** stop mid-week rebases, cap PR bursts and delay Action automerge by three days ([523cc83](https://github.com/dodi-smart/.github/commit/523cc83e8bdd026a75799cbaa4736ab34b37c9a2))

## [1.8.1](https://github.com/dodi-smart/.github/compare/v1.8.0...v1.8.1) (2026-09-29)

### 🐛 Bug Fixes

* **release:** move v1 only after Self test passes on the commit being released ([1ad287b](https://github.com/dodi-smart/.github/commit/1ad287b72cc657676dba4964a6ee3c29bbddb269))

## [1.8.0](https://github.com/dodi-smart/.github/compare/v1.7.6...v1.8.0) (2026-09-29)

### ✨ Features

* **deps-verify:** fix what an update breaks and post a short, deterministic verdict ([08cf95f](https://github.com/dodi-smart/.github/commit/08cf95fd86c8932aad84f18ebf015a425d6899eb))
* **deps-verify:** read the pr-checks verdict instead of building a second time beside it ([96ae3c9](https://github.com/dodi-smart/.github/commit/96ae3c9143138c71b2ba2d5bcdcd780516f143e6))

## [1.7.6](https://github.com/dodi-smart/.github/compare/v1.7.5...v1.7.6) (2026-09-29)

### 🐛 Bug Fixes

* **release:** install semantic-release with --no-save so it never lands in the caller's manifest ([ccf671a](https://github.com/dodi-smart/.github/commit/ccf671aaf33d90fec24c63a7981e208e60e84968))

## [1.7.5](https://github.com/dodi-smart/.github/compare/v1.7.4...v1.7.5) (2026-09-28)

### ⬆️ Dependencies

* **deps:** update supabase/setup-cli action to v3.0.1 ([#65](https://github.com/dodi-smart/.github/issues/65)) ([a0e2e3c](https://github.com/dodi-smart/.github/commit/a0e2e3c8a9435b5da94b9e4cc96a0b340e36c3ed))

## [1.7.4](https://github.com/dodi-smart/.github/compare/v1.7.3...v1.7.4) (2026-09-23)

### ⬆️ Dependencies

* **deps:** update semantic-release monorepo ([2f61cd3](https://github.com/dodi-smart/.github/commit/2f61cd3330d2496a3d51b6f7f22830eda96f90d0))

## [1.7.3](https://github.com/dodi-smart/.github/compare/v1.7.2...v1.7.3) (2026-09-17)

### 🐛 Bug Fixes

* **pr-review:** review for security, performance and practices, not only bugs ([40b2edc](https://github.com/dodi-smart/.github/commit/40b2edc739b064193eb869dbb2816e9335d01f00))
* **pr-review:** shorter verdicts and no elevated depth for caller edits ([b067229](https://github.com/dodi-smart/.github/commit/b0672291e10a53d9e917ec9e4bf7bd4baecf2b20))

## [1.7.2](https://github.com/dodi-smart/.github/compare/v1.7.1...v1.7.2) (2026-09-14)

### 🐛 Bug Fixes

* **agents:** stop triage on bot-sent events and recover a review verdict the agent did not file ([056b636](https://github.com/dodi-smart/.github/commit/056b636a4177451e6e5e32ffa027fea42d642348)), closes [#36](https://github.com/dodi-smart/.github/issues/36) [#37](https://github.com/dodi-smart/.github/issues/37)

## [1.7.1](https://github.com/dodi-smart/.github/compare/v1.7.0...v1.7.1) (2026-09-14)

### ⬆️ Dependencies

* **deps:** lock file maintenance ([0daffa3](https://github.com/dodi-smart/.github/commit/0daffa377b589407255379a163a48475f0026057))
* **deps:** pin dependency semantic-release to 25.0.9 ([5556d09](https://github.com/dodi-smart/.github/commit/5556d090a5dfe7349f7191298c34f8f9b871fdb8))

## [1.7.0](https://github.com/dodi-smart/.github/compare/v1.6.2...v1.7.0) (2026-09-14)

### ✨ Features

* **pr-checks:** add opt-in design-lint step for oxlint + @shadcn/lint ([81f222f](https://github.com/dodi-smart/.github/commit/81f222f24c61ddb1dd8d74d0cde97f8b880d1ab2))

## [1.6.2](https://github.com/dodi-smart/.github/compare/v1.6.1...v1.6.2) (2026-09-14)

### 🐛 Bug Fixes

* **release:** push the release commit and backmerge with the org App token ([39e4d1d](https://github.com/dodi-smart/.github/commit/39e4d1d2b0ea15ff1757940474c577d19e94e13d))

## [1.6.1](https://github.com/dodi-smart/.github/compare/v1.6.0...v1.6.1) (2026-09-12)

### ⚡ Performance Improvements

* **agent-workflows:** one hosted job start per agent run ([e70c0da](https://github.com/dodi-smart/.github/commit/e70c0da28aa947564411fe983e70d27c029108fd))

## [1.6.0](https://github.com/dodi-smart/.github/compare/v1.5.0...v1.6.0) (2026-09-12)

### ✨ Features

* **pr-checks:** one hosted picker job and an always-on pr-checks summary ([aef1c40](https://github.com/dodi-smart/.github/commit/aef1c406d5df6ca215bebd191b2db8098e37e356))

## [1.5.0](https://github.com/dodi-smart/.github/compare/v1.4.0...v1.5.0) (2026-09-12)

### ✨ Features

* **workflows:** add reusable Supabase deploy workflow ([e843f96](https://github.com/dodi-smart/.github/commit/e843f962f83ade6f3b107a21ea70c1b23abadcdb))

## [1.4.0](https://github.com/dodi-smart/.github/compare/v1.3.2...v1.4.0) (2026-09-12)

### ✨ Features

* add supabase-checks reusable workflow ([10a08cb](https://github.com/dodi-smart/.github/commit/10a08cb9e190ac570f4fe655b90fcc4cfb6fa3a9))

## [1.3.2](https://github.com/dodi-smart/.github/compare/v1.3.1...v1.3.2) (2026-09-12)

### 🐛 Bug Fixes

* make issue-triage's workflow_dispatch trigger do something or fail clean ([0cfe73c](https://github.com/dodi-smart/.github/commit/0cfe73c71587ff9f6a7c9d59fb1a0d71634ac81f))

## [1.3.1](https://github.com/dodi-smart/.github/compare/v1.3.0...v1.3.1) (2026-09-12)

### 🐛 Bug Fixes

* **release:** resolve lockfiles on backmerge, add backmerge-resolve-paths ([bca5a90](https://github.com/dodi-smart/.github/commit/bca5a9017c6328cef47ccd6ef2d9b87acc1309a1))

## [1.3.0](https://github.com/dodi-smart/.github/compare/v1.2.0...v1.3.0) (2026-09-10)

### ✨ Features

* **semantic-release:** let git() take a commit message and github() pass options through ([d5f48d0](https://github.com/dodi-smart/.github/commit/d5f48d07ef5294146ee1f499c7156a2d3e601b27))

## [1.2.0](https://github.com/dodi-smart/.github/compare/v1.1.5...v1.2.0) (2026-09-10)

### ✨ Features

* **semantic-release:** shared config package linked into consumers, pinned to render the conventionalcommits v10 preset ([2e4d8f5](https://github.com/dodi-smart/.github/commit/2e4d8f5f3f631b6a9bd2aae0277787aa0e28d5d7))

## [1.1.5](https://github.com/dodi-smart/.github/compare/v1.1.4...v1.1.5) (2026-09-08)

### 🐛 Bug Fixes

* **renovate:** name the shared preset default.json, the only filename Renovate fetches ([5787547](https://github.com/dodi-smart/.github/commit/5787547a03f8abb084df042fab9c17a60456b86d))

## [1.1.4](https://github.com/dodi-smart/.github/compare/v1.1.3...v1.1.4) (2026-09-08)

### 🐛 Bug Fixes

* **pr-review:** publish the review through a file the job requires ([b947fde](https://github.com/dodi-smart/.github/commit/b947fdec4b0b845e240a2964a3f9e64c710a269c)), closes [dodi-smart/infrasensing-senslogging#152](https://github.com/dodi-smart/infrasensing-senslogging/issues/152)
* **pr-review:** say when claude-code-action skipped instead of blaming the prompt ([56cf1ce](https://github.com/dodi-smart/.github/commit/56cf1ce2e73fd291d9f90344de7fad876d8ad5e6))

## [1.1.3](https://github.com/dodi-smart/.github/compare/v1.1.2...v1.1.3) (2026-09-03)

### 🐛 Bug Fixes

* **run-agent:** support reopened issues by dropping a progress comment tag mode cannot render ([bd29ece](https://github.com/dodi-smart/.github/commit/bd29ece7b98bc37d374c5c8ab5a712b59104c2cd))

## [1.1.2](https://github.com/dodi-smart/.github/compare/v1.1.1...v1.1.2) (2026-09-01)

### 🐛 Bug Fixes

* **release:** ignore tags from other branches and never pick a prerelease as newest ([8674250](https://github.com/dodi-smart/.github/commit/867425053383c5c331b8b460f86a85340602e791))

## [1.1.1](https://github.com/dodi-smart/.github/compare/v1.1.0...v1.1.1) (2026-08-31)

### 🐛 Bug Fixes

* **release:** backmerge auto-resolves version-file conflicts toward the release branch ([68afbdb](https://github.com/dodi-smart/.github/commit/68afbdbcfbe85b9d18484fb450caed4d8d388a64))

## [1.1.0](https://github.com/dodi-smart/.github/compare/v1.0.6...v1.1.0) (2026-08-31)

### ✨ Features

* **release:** expose released/version/tag/tags workflow outputs ([7463594](https://github.com/dodi-smart/.github/commit/7463594526627638be8e1d1c3531bb03d1a7e268))

## [1.0.6](https://github.com/dodi-smart/.github/compare/v1.0.5...v1.0.6) (2026-08-29)

### 🐛 Bug Fixes

* **agent-gate:** make 'bots: only' mean dependency bots, not any [bot] author ([f047672](https://github.com/dodi-smart/.github/commit/f047672e2cdc074e2c179b8ef679917eba9c293c))

## [1.0.5](https://github.com/dodi-smart/.github/compare/v1.0.4...v1.0.5) (2026-08-29)

### 🐛 Bug Fixes

* **deps-verify:** lead the verdict comment with the verdict and keep prose out of table cells ([4a645fb](https://github.com/dodi-smart/.github/commit/4a645fb13f201afd7654e296e3a0383088317baf))
* **zavet-check:** report without failing the job on dependency bot PRs ([415ac95](https://github.com/dodi-smart/.github/commit/415ac95c118e8bbd9cfafa37958f15aa89a53870))

## [1.0.4](https://github.com/dodi-smart/.github/compare/v1.0.3...v1.0.4) (2026-08-28)

### 🐛 Bug Fixes

* **zavet-check:** report a check that could not run apart from one that failed ([d1769c5](https://github.com/dodi-smart/.github/commit/d1769c50cc890b9b7892a4a4b712c9f4339347ed))
* **zavet-check:** run the real check runner, and separate cannot-run from failed ([644c290](https://github.com/dodi-smart/.github/commit/644c29003ba439bff895ce840b03d88736d2fd44))

## [1.0.3](https://github.com/dodi-smart/.github/compare/v1.0.2...v1.0.3) (2026-08-25)

### 🐛 Bug Fixes

* **setup-stack:** name a channel in the rust ref, and drop a vendor name from the bug template ([b0cf573](https://github.com/dodi-smart/.github/commit/b0cf573635bacaef84338b4fac070a13337de7bc))

## [1.0.2](https://github.com/dodi-smart/.github/compare/v1.0.1...v1.0.2) (2026-08-25)

### 🐛 Bug Fixes

* **ci:** run Self test on every pull request, not a filtered subset ([bee32dc](https://github.com/dodi-smart/.github/commit/bee32dcdeadfdebdad99afb452b89d5dd8ea57f5))

### ⬆️ Dependencies

* **deps:** update actions/setup-java action to v6 ([b53a5c2](https://github.com/dodi-smart/.github/commit/b53a5c2c98076fb7bc0764291c7eacca45e4d371))

## [1.0.1](https://github.com/dodi-smart/.github/compare/v1.0.0...v1.0.1) (2026-08-25)

### 🐛 Bug Fixes

* **release:** cut a patch when a dependency updates ([7e119f1](https://github.com/dodi-smart/.github/commit/7e119f12523900e666cb040b649bdc52a82271a4))

## 1.0.0 (2026-08-25)

### Features

* **actions:** the agent gate, the agent runner, stack setup, sticky comments ([489a36c](https://github.com/dodi-smart/.github/commit/489a36c95c76148e97f61ed324a1637d1b51c7c1))
* document the standard, test it, and release it automatically ([fa717aa](https://github.com/dodi-smart/.github/commit/fa717aa800d4ff0224ed79861e94aaa482599d68))
* org issue templates and the shared Renovate preset ([79be958](https://github.com/dodi-smart/.github/commit/79be9584ef34673ffc0cb50f09ae79af637891b5))
* **runners:** select runners by capability, and validate the selection ([feb0e18](https://github.com/dodi-smart/.github/commit/feb0e18516d88bc5f0580e5c7a6192f9eddca094))
* **workflows:** checks, dependency verification, review, react doctor, release ([653de59](https://github.com/dodi-smart/.github/commit/653de59bd16ead3fb93d20a2c45eec41b2aac477))
* **workflows:** issue triage and implementation, assistant, knowledge checks ([c9842c8](https://github.com/dodi-smart/.github/commit/c9842c8b509d118cf89a29925a2a6ce964a712cf))
