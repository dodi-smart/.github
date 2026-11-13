# The reader of the `Agent run` notice action.yml's outcome step writes, kept
# beside its writer: one notice message in, {cost, issue, pr} out. `cost` is
# null for an unpriced run (`cost=?`), never 0. factory.sh reads spend with it.
sub(" \\(.*\\)$"; "") | [scan("([a-z]+)=([^ ]*)") | {key: .[0], value: .[1]}] | from_entries
| {cost: ((.cost | tonumber?) // null), issue: ((.issue | tonumber?) // null), pr: ((.pr | tonumber?) // null)}
