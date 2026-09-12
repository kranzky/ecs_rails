# Bounded demo lists (ECS-31)

Use Kaminari's ordinary ActiveRecord relations and view helpers in the demo.
Every list page contains at most 24 entities. Apply the page before component
and relationship preloads, so object allocation follows the requested page.
Every ordering ends in the entity UUID; equal dates, prices, ratings or likes
must not repeat or skip records when moving between pages of an unchanged list.

Cover the market, bulletin, sellers, people, groups and order history, plus
reviews, comments, group memberships, seller products/staff and a person's
posts. Seller staff uses `staff_page` independently of its products' `page`.
Pagination links retain query parameters; changing filters starts on page one.
Headings show the total matching count rather than the current page's count.

Absent, malformed, zero, negative or more than nine-digit page parameters mean
page one. A valid page past the end resolves to the last page, or page one for
an empty relation. Normalize before an offset query and retain the library's
count/navigation behavior. Offset pagination gives deterministic navigation
for an unchanged result set; concurrent insertions can still shift page edges.

Keep this a demo concern: no gem API, schema or migration changes. Form actor
pickers and complete basket/invoice/order contents are not browsing lists;
searchable pickers and changes to checkout presentation are separate work.

Request specs cover boundaries, invalid input, empty filters, tied sorts,
filter-preserving links and nested lists. Observe ActiveRecord instantiation
and rendered cards to prove that adding off-page products does not increase
the loaded/rendered page or its preloaded components and seller targets.
