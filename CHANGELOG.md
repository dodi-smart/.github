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
