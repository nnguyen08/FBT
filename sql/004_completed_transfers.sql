CREATE VIEW completed_transfers AS
SELECT *
FROM transfers
WHERE transfer_date <= CURRENT_DATE;