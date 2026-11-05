from suggester.firefly import Txn
from suggester.llm import Classification

_ids = iter(range(1000, 100000))


def txn(description, destination="(unknown destination)", destination_id=9, category=None, journal_id=None, type="withdrawal"):
    jid = journal_id or next(_ids)
    return Txn(
        transaction_id=jid,
        journal_id=jid,
        type=type,
        date="2026-10-12",
        amount="10.00",
        currency="EUR",
        description=description,
        destination_id=destination_id,
        destination_name=destination,
        category=category,
    )


def classification(category="Shopping", confidence=0.9, keywords=(), destination=False, person=False, company=None):
    return Classification(
        category=category,
        confidence=confidence,
        company=company,
        reason="test",
        description_keywords=list(keywords),
        use_destination=destination,
        counterparty_is_person=person,
    )
