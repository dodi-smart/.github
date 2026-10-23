# Security policy

This is the default security policy for every dodi-smart repository that does
not carry its own `SECURITY.md`. A repository with its own policy, for example
one that names the product's manufacturer as the contact, follows that one
instead.

## Reporting a vulnerability

<!-- TODO(security-contact): replace example.invalid with the real mailbox -->
Email **security@example.invalid**. Please do not open a public issue, pull
request or discussion for a security problem.

Include as much of this as you can:

- the repository, product or service and the version you tested
- what an attacker can do, and what they need first
- steps to reproduce, or a proof of concept
- how to reach you, and whether you want to be credited

## What happens next

| Step | Target |
|---|---|
| We acknowledge your report | 2 working days |
| We confirm whether it is a vulnerability and how severe it is | 5 working days |
| A fix is available for a **critical** issue | 72 hours |
| A fix is available for a **high** issue | 7 days |
| A fix is available for a **medium** issue | 30 days |
| A fix is available for a **low** issue | 90 days |

Severity starts from the CVSS score and is raised when the issue is actively
exploited or needs no authentication.

## Disclosure

We follow coordinated disclosure. We agree a publication date with you,
normally when the fix is available and at most 90 days after your report, then
publish an advisory naming the affected versions, the impact and the fix. We
credit you unless you ask us not to.

## Safe harbour

We will not take legal action against research that is done in good faith,
stays within this policy, avoids harm to users and their data, and gives us a
reasonable time to fix the issue before it is disclosed.

## Shared workflows and actions

For the reusable workflows and actions in this repository, the supported
version is the current `v1` channel. A fix is released on `next` first and
then promoted to `v1`.
