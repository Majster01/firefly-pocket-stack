import unittest

from suggester.normalize import COMPANY, PERSON, UNKNOWN, classify_counterparty, group_transactions, normalize_description
from tests.helpers import txn


class NormalizeDescription(unittest.TestCase):
    def test_strips_bank_noise(self):
        cases = {
            "NAKUP HETZNER ONLINE GMBH 8,65 EUR": "HETZNER ONLINE GMBH",
            "NAKUP GOOGLE*CLOUD AB3C4D 4,72 EUR": "GOOGLE*CLOUD",
            "SI121234567890123 STORITVE 28.8. DO 27.9.2026": "STORITVE DO",
            "SI0012345-6789-10111213141 PLAČILA FLIK SPLETNI NAKUP": "PLAČILA FLIK SPLETNI NAKUP",
            "SI1912345678-90123 PLAČILO DAVKA": "PLAČILO DAVKA",
            "NRC00 skupno kosilo, ŽAN K. 0038640000000": "SKUPNO KOSILO, ŽAN K",
            "BLAGAJNA CENTER - 73": "BLAGAJNA CENTER",
            "SumUp  *Kavarna ob reki": "SUMUP *KAVARNA OB REKI",
            "NAKUP AMAZON 1.234,50 EUR": "AMAZON",
        }
        for raw, expected in cases.items():
            with self.subTest(raw=raw):
                self.assertEqual(normalize_description(raw), expected)

    def test_keeps_names_with_a_single_digit(self):
        self.assertEqual(normalize_description("A1 SLOVENIJA"), "A1 SLOVENIJA")

    def test_same_merchant_different_amounts_normalise_alike(self):
        self.assertEqual(
            normalize_description("NAKUP HETZNER ONLINE GMBH 8,65 EUR"),
            normalize_description("NAKUP HETZNER ONLINE GMBH 0,17 EUR"),
        )


class Counterparty(unittest.TestCase):
    def test_unknown_destination(self):
        self.assertEqual(classify_counterparty(txn("HOMEDECO CENTER")), UNKNOWN)

    def test_instant_payment_to_a_name_is_a_person(self):
        self.assertEqual(classify_counterparty(txn("NRC00 PISARNA", "MARKO HORVAT", 12)), PERSON)
        self.assertEqual(classify_counterparty(txn("kosilo", "ŽAN K.", 29)), PERSON)

    def test_legal_form_wins_over_instant_payment(self):
        self.assertEqual(classify_counterparty(txn("NRC00 racun", "PRIMER D.O.O.", 40)), COMPANY)

    def test_public_bodies_and_companies(self):
        self.assertEqual(classify_counterparty(txn("x", "A1 SLOVENIJA, D. D.", 16)), COMPANY)
        self.assertEqual(classify_counterparty(txn("x", "OBCINA VZOREC", 28)), COMPANY)
        self.assertEqual(classify_counterparty(txn("x", "PDP - ZZZS", 25)), COMPANY)


class Grouping(unittest.TestCase):
    def test_unknown_destination_groups_by_normalised_description(self):
        groups = group_transactions(
            [
                txn("NAKUP HETZNER ONLINE GMBH 8,65 EUR"),
                txn("NAKUP HETZNER ONLINE GMBH 0,17 EUR"),
                txn("HOMEDECO CENTER"),
            ]
        )
        self.assertEqual(sorted(len(g.txns) for g in groups), [1, 2])

    def test_company_groups_by_destination_whatever_the_description(self):
        groups = group_transactions(
            [
                txn("SI12 STORITVE 28.8. DO 27.9.2026", "A1 SLOVENIJA, D. D.", 16),
                txn("SI12 STORITVE 28.9. DO 27.10.2026", "A1 SLOVENIJA, D. D.", 16),
                txn("RACUN 5", "A1 SLOVENIJA, D. D.", 16),
            ]
        )
        self.assertEqual(len(groups), 1)
        self.assertEqual(groups[0].counterparty, COMPANY)

    def test_people_never_merge_with_each_other(self):
        groups = group_transactions(
            [txn("NRC00 kosilo", "ŽAN K.", 29), txn("NRC00 kosilo", "EVA P.", 30)]
        )
        self.assertEqual(len(groups), 2)
        self.assertTrue(all(g.counterparty == PERSON for g in groups))


if __name__ == "__main__":
    unittest.main()
