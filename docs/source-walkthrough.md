# Reading an ECS Rails application

This walkthrough follows the unreleased 0.3.0 source. Start with the
[gem README](../gem/README.md#quickstart-a-contacts-directory) for installation,
then follow these three paths through the companion demo. You can understand the application
without starting with the gem's metaprogramming.

## From installation to an entity

The [install generator](../gem/lib/generators/ecs_rails/install/install_generator.rb)
writes the entity/component bases, catalogue classes, initializer and one
migration. A generated component includes its catalogue concern: the app chooses
its class name and the gem supplies behavior and schema. Compare the demo's
[Text class](../demo/app/entities/components/text.rb) with
[Catalogue::Text](../gem/lib/ecs_rails/catalogue/text.rb). The initializer's
Zeitwerk collapse keeps component constants top-level even though their files
live under `components/`.

The [entity generator](../gem/lib/generators/ecs_rails/entity/entity_generator.rb)
turns references such as `name home:address` into ordinary declarations without
adding storage. The quickstart runs it before adding links and markers in Ruby.

[Product](../demo/app/entities/product.rb) is the useful next file. Its title
and body are two slots of Text, its price is Money, and its seller is a
relationship to Company. `product.title` returns Text's primary value;
`product.title_text` returns the component object. Add another catalogue slot in
Ruby and use the existing table. Upgrading the catalogue or adding a bespoke
component can still require a migration.

Reading an absent component returns a virtual object with column defaults.
Reading may query the database; virtual does not mean query-free. Assign values
through the component reader or delegated attributes, then save the entity.
Only values differing from defaults need a row. Validation errors are merged
onto the entity, and touched components save in its transaction. See
[Lazy](../gem/lib/ecs_rails/lazy.rb) and
[Validations](../gem/lib/ecs_rails/validations.rb) when you need that lifecycle's
details; the [lazy component specs](../gem/spec/lazy_spec.rb) pin the contract.

For a read path, follow
[ProductsController#index](../demo/app/controllers/products_controller.rb) into
Product's scopes and then the
[catalogue view](../demo/app/views/products/index.html.erb). The controller
normalizes parameters, composes a relation, paginates and preloads before ERB
renders it. Component-presence filters use correlated `EXISTS`; the demo's price
filter deliberately uses a slot-scoped left join so a missing price displays
and sorts as zero. `includes_components(Text)` loads every declared Text slot;
ordinary Rails `preload(:title_text)` can load just the title. An undeclared
component query can match stored rows: querying is distinct from the declaration
checks used by the presence API.

## From checkout form to immutable documents

[CheckoutsController](../demo/app/controllers/checkouts_controller.rb) handles
HTTP concerns: permitted address fields, normalization, the same-billing choice,
and redirects. It passes plain values and the basket into
[Demo::Checkout](../demo/lib/demo/checkout.rb).

Read `Checkout#call` from top to bottom. It locks the basket, recognizes a
completed submission by revision, rejects stale or empty submissions, locks
stock, creates an order, adds lines, takes payment, issues an invoice and clears
the basket. `create_order`, `add_line` and `pay_order` give the details of those
steps. Address, title and price snapshots keep later catalogue edits from
changing the sale. [Invoice.issue_for](../demo/app/entities/invoice.rb) copies
the order's billing address and total into the final document.

Keep the lock and transaction comments when changing this code. Basket revisions
and request identifiers make a completed repeat return the original order;
sorted stock locks and [Numbering](../demo/lib/demo/numbering.rb) coordinate
competing checkouts. A simulated payment decline raises inside the transaction
and rolls everything back. This demo's
[PaymentGateway](../demo/lib/demo/payment_gateway.rb) does not make an external
charge; a real provider needs its own payment/idempotency design.

This service knows the marketplace's entity classes. That is appropriate for
this application workflow. Its behavior is covered by
[checkout specs](../demo/spec/checkout_spec.rb),
[concurrent checkout specs](../demo/spec/checkout_concurrency_spec.rb) and
[rendered request specs](../demo/spec/checkout_requests_spec.rb), including
same/separate billing addresses, normalization, replay and stale forms.

## A system that does not know the entity types

[Demo::Indexer](../demo/lib/demo/indexer.rb) is the contrasting reusable system.
It finds owners of Text rows in bounded batches, checks each owner's class for
a SearchVector declaration, collects all eligible owners' text slots, and calls
the catalogue's
[SearchVector#reindex!](../gem/lib/ecs_rails/catalogue/search_vector.rb).
It names no Product or Post class. Another entity type participates by declaring
the relevant components.

The batch unit is an owner, because splitting one owner's text across batches
would replace its search document with the last fragment. Values are fetched
with `pluck`; existing vectors are loaded together. The
[indexer specs](../demo/spec/indexer_spec.rb) cover unfamiliar entity types,
complete documents, repeated runs and batch boundaries. Use
[the performance comparison](design/performance-comparison.md) to understand
the remaining costs before changing this path.

## When to open the DSL internals

[DSL](../gem/lib/ecs_rails/dsl.rb) turns declarations into slot-scoped
associations and delegated methods. [Relationships](../gem/lib/ecs_rails/relationships.rb)
and [Inverses](../gem/lib/ecs_rails/inverses.rb) build the corresponding Rails
association paths. [Querying](../gem/lib/ecs_rails/querying.rb) and
[Preloading](../gem/lib/ecs_rails/preloading.rb) extend relations. This is where
dynamic method generation belongs; application controllers and systems remain
ordinary Ruby and Rails code.

The comments about reload-safe class names, declaration collisions, lazy saves
and Rails-generated method guards explain correctness constraints. Read their
linked ADRs/RFCs before changing those boundaries. The ECS-36 review preserves
these contracts and dependencies, simplifies checkout's orchestration and
Period's branching, and corrects examples and comments that had drifted from
the catalogue API. The executable quickstart and demo setup are documented in
their READMEs; performance changes have their own 0.4.0 issues.
