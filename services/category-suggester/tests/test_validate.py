import unittest

from suggester.normalize import group_transactions
from suggester.store import trigger_key
from suggester.validate import ExistingRules, build_suggestions
from tests.helpers import classification, txn

CATEGORIES = {"Shopping", "Food & Drink", "Bills", "Subscriptions", "Business", "Transport"}


def build(group, result, *, matches=None, existing=None, rejected=frozenset(), min_confidence=0.6):
    """matches: query -> extra transactions Firefly would return besides the group's own."""
    matches = matches or {}

    def search(query):
        return list(group.txns) + matches.get(query, [])

    return build_suggestions(
        group,
        result,
        categories=CATEGORIES,
        existing=existing or ExistingRules(),
        search=search,
        min_confidence=min_confidence,
        model="test",
        rejected=rejected,
    )


def one_group(*txns):
    groups = group_transactions(list(txns))
    assert len(groups) == 1, groups
    return groups[0]


class DescriptionKeywords(unittest.TestCase):
    def test_good_keyword_is_kept(self):
        group = one_group(txn("HOMEDECO CENTER"), txn("HOMEDECO CENTER"))
        [s] = build(group, classification(keywords=["HOMEDECO"]))
        self.assertEqual(s.triggers, [("description_contains", "HOMEDECO")])
        self.assertFalse(s.low_confidence)
        self.assertEqual(len(s.transactions), 2)

    def test_short_generic_and_missing_keywords_are_dropped(self):
        group = one_group(txn("BURGERLAB LJ-CENTER"))
        [s] = build(group, classification("Food & Drink", keywords=["CENTER", "LJ-CENTER", "BURGERS", "HOO", "BURGERLAB"]))
        self.assertEqual(s.triggers, [("description_contains", "BURGERLAB")])
        reasons = {value: why for _, value, why in s.rejected}
        self.assertIn("generic", reasons["CENTER"])
        self.assertIn("generic", reasons["LJ-CENTER"])
        self.assertIn("not a substring", reasons["BURGERS"])
        self.assertIn("shorter", reasons["HOO"])

    def test_keyword_must_be_in_every_description(self):
        group = one_group(txn("GORSKI SPORT X", "GORSKI D.O.O.", 50), txn("WWW.GORSKISPORT.SI", "GORSKI D.O.O.", 50))
        [s] = build(group, classification(keywords=["GORSKI SPORT"], destination=True))
        self.assertEqual(s.triggers, [("destination_account_id", "50")])

    def test_already_in_categorization(self):
        group = one_group(txn("LIDL-SI 123"))
        existing = ExistingRules(description={"lidl-si 123"})
        suggestions = build(group, classification("Food & Drink", keywords=["LIDL-SI 123"]), existing=existing)
        self.assertEqual(suggestions, [])  # nor the full-description fallback, which is the same text

    def test_keyword_conflicting_with_categorized_history_is_dropped(self):
        group = one_group(txn("NAKUP HETZNER ONLINE GMBH 8,65 EUR"))
        old = txn("NAKUP HETZNER ONLINE GMBH 0,17 EUR", category="Subscriptions")
        [s] = build(group, classification("Business", keywords=["HETZNER"]), matches={'description_contains:"HETZNER"': [old]})
        self.assertIn("too generic", s.rejected[0][2])
        self.assertEqual(s.triggers, [("description_contains", "NAKUP HETZNER ONLINE GMBH 8,65 EUR")])
        self.assertIn("falling back", s.notes[-1])

    def test_same_category_history_is_fine(self):
        group = one_group(txn("NAKUP HETZNER ONLINE GMBH 8,65 EUR"))
        old = txn("NAKUP HETZNER ONLINE GMBH 0,17 EUR", category="Subscriptions")
        [s] = build(group, classification("Subscriptions", keywords=["HETZNER"]), matches={'description_contains:"HETZNER"': [old]})
        self.assertEqual(s.triggers, [("description_contains", "HETZNER")])

    def test_keyword_catching_another_uncategorized_merchant_is_dropped(self):
        group = one_group(txn("BAR CENTRAL"))
        other = txn("BAR TERRAZA")
        [s] = build(group, classification("Food & Drink", keywords=["BAR C", "CENTRAL"]), matches={'description_contains:"BAR C"': [other]})
        self.assertEqual(s.triggers, [("description_contains", "CENTRAL")])

    def test_quote_in_keyword_is_refused(self):
        group = one_group(txn('PIZZA "NAPOLI"'))
        [s] = build(group, classification("Food & Drink", keywords=['"NAPOLI"', "PIZZA"]))
        self.assertEqual(s.triggers, [("description_contains", "PIZZA")])


class DestinationTriggers(unittest.TestCase):
    def test_company_destination_is_used(self):
        group = one_group(txn("SI12 STORITVE 28.8.", "A1 SLOVENIJA, D. D.", 16))
        [s] = build(group, classification("Bills", destination=True, company="A1 Slovenija — telecom"))
        self.assertEqual(s.triggers, [("destination_account_id", "16")])
        self.assertEqual(s.basis, "destination")
        self.assertEqual(s.title, "Suggest: Bills · A1 Slovenija")

    def test_unknown_destination_is_never_a_trigger(self):
        group = one_group(txn("ANTHROPIC CLAUDE"))
        [s] = build(group, classification("Subscriptions", keywords=["ANTHROPIC"], destination=True))
        self.assertEqual(s.triggers, [("description_contains", "ANTHROPIC")])
        self.assertTrue(all(value != "(unknown destination)" for _, value in s.triggers))

    def test_person_never_gets_a_destination_trigger(self):
        group = one_group(txn("NRC00 skupno kosilo", "ŽAN K.", 29))
        [s] = build(group, classification("Food & Drink", keywords=["skupno kosilo"], destination=True))
        self.assertEqual(s.triggers, [("description_contains", "skupno kosilo")])

    def test_model_can_demote_a_company_to_a_person(self):
        group = one_group(txn("PLAČILO", "JANEZ NOVAK", 31))
        [s] = build(group, classification("Bills", keywords=[], destination=True, person=True))
        self.assertNotIn("destination_account_id", [t for t, _ in s.triggers])
        self.assertIn("private person", s.notes[0])

    def test_destination_already_covered_by_categorization(self):
        group = one_group(txn("PLAČILO RAČUNA 90", "VZOREC CAPITAL D.O.O.", 7))
        existing = ExistingRules(destination_names={"vzorec capital d.o.o."})
        [s] = build(group, classification("Bills", destination=True), existing=existing)
        self.assertEqual(s.triggers, [("description_contains", "PLAČILO RAČUNA 90")])


class LowConfidence(unittest.TestCase):
    def test_low_confidence_uses_the_full_description_only(self):
        group = one_group(txn("SP FROSTFOX"))
        [s] = build(group, classification("Food & Drink", confidence=0.4, keywords=["FROSTFOX"]))
        self.assertTrue(s.low_confidence)
        self.assertEqual(s.triggers, [("description_contains", "SP FROSTFOX")])
        self.assertEqual(s.metadata("2026-10-29")["low_confidence"], True)

    def test_low_confidence_splits_by_description(self):
        group = one_group(txn("x", "OBCINA VZOREC", 28, journal_id=1), txn("y plačilo", "OBCINA VZOREC", 28, journal_id=2))
        suggestions = build(group, classification("Bills", confidence=0.3, destination=True))
        self.assertEqual(sorted(s.triggers[0][1] for s in suggestions), ["y plačilo"])  # "x" is under 4 chars
        self.assertEqual([t.journal_id for t in suggestions[0].transactions], [2])

    def test_unknown_category_raises(self):
        group = one_group(txn("HOMEDECO"))
        with self.assertRaises(ValueError):
            build(group, classification("Furniture", keywords=["HOMEDECO"]))


class RejectionMemory(unittest.TestCase):
    def test_rejected_keyword_is_not_suggested_again(self):
        group = one_group(txn("HOMEDECO CENTER"))
        rejected = {trigger_key("description_contains", "homedeco", "Shopping")}
        [s] = build(group, classification("Shopping", keywords=["HOMEDECO"]), rejected=rejected)
        self.assertNotIn(("description_contains", "HOMEDECO"), s.triggers)
        self.assertIn("rejected before", s.rejected[0][2])

    def test_same_keyword_with_another_category_is_allowed(self):
        group = one_group(txn("HOMEDECO CENTER"))
        rejected = {trigger_key("description_contains", "HOMEDECO", "Bills")}
        [s] = build(group, classification("Shopping", keywords=["HOMEDECO"]), rejected=rejected)
        self.assertEqual(s.triggers, [("description_contains", "HOMEDECO")])

    def test_rejected_full_description_covers_other_amounts(self):
        group = one_group(txn("NAKUP ZAGREBACKI HOLDING d.o 2,10 EUR"))
        rejected = {trigger_key("description_contains", "NAKUP ZAGREBACKI HOLDING d.o 1,40 EUR", "Transport")}
        suggestions = build(group, classification("Transport", confidence=0.5), rejected=rejected)
        self.assertEqual(suggestions, [])


if __name__ == "__main__":
    unittest.main()
