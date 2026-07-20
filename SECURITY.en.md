# Security policy

## Document status

This policy applies to the source version identified by a published release. No public update
schedule, remediation timeline, or security SLA is provided. The existence of a release does not
mean that the implementation has undergone an independent cryptographic audit.

An organization that uses the source code in its own environment is responsible for its fork,
dependency updates, audits, key management, incident response, and remediation.

## Reporting a material vulnerability

Do not disclose active credentials, private keys, seed phrases, device tokens, personal data, or
exploitation details in a public GitHub issue or discussion. Repository community features should
remain disabled.

If **Private vulnerability reporting** is enabled for the repository, a private report can be
submitted through **Security → Report a vulnerability**. Availability of this channel does not
establish a response SLA or an obligation to remediate or publish a new release.

A safe report should contain:

1. the affected commit;
2. prerequisites and a minimal reproducible scenario;
3. the confidentiality, integrity, and availability impact;
4. redacted evidence without production secrets;
5. a possible remediation, if known.

## Known limitations

- neither the protocol nor its implementation has undergone an independent security audit;
- the server can observe the routing metadata listed in `docs/threat-model.en.md`;
- network anonymity is outside the project scope;
- compromise of an unlocked device is outside part of the stated guarantees;
- the single-node Compose topology requires infrastructure changes for high availability;
- automated dependency checks do not replace an assessment of whether a new vulnerability applies
  to a specific deployment.

The trust model for version `2.0.0` is documented in
[docs/threat-model.en.md](docs/threat-model.en.md).
