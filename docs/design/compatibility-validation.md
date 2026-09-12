# Compatibility and package validation (ECS-30)

The gem advertises Ruby >= 3.2 and Rails >= 7.1, < 9. CI must exercise each
released Rails minor in that range, the Ruby lower boundary, and current Ruby:
3.2/7.1, 3.2/7.2, 3.3/8.0, 3.2/8.1, 3.4/8.1 and 4.0/8.1. Resolve patch releases
within each minor; record the resolved versions in job output. This is a
representative matrix, not every Cartesian combination or a promise about
unreleased Rails/Ruby versions.

Each matrix entry runs PostgreSQL gem specs and builds/installs the actual gem
package into temporary Rails applications. One follows the catalogue quickstart
and renders a page after eager loading. A second starts with the published
0.2.2 package, persists component/relationship/marker rows, then switches to the
candidate package and verifies the generated upgrade preserves those rows.
Separate gem installation directories distinguish the two packages even while
the unreleased candidate still carries version 0.2.2.

Package checks create uniquely named databases through the supplied PostgreSQL
connection, keep ownership of those names, and drop only those databases in
cleanup. They never reset a developer's working demo. The demo has its own test
database and CI job; its test-only guard remains enforced. Documentation has a
separate job that fails on undocumented public API. CI uploads the candidate gem
and resolved dependency records for review.

JSON 3 rejects positional option hashes still used by supported Rails decoders.
The existing development-only JSON < 3 constraint therefore moves to the gem's
runtime dependencies, so package consumers receive the tested dependency range.
