.PHONY: up refresh test

up:            ## start Postgres
	docker compose up -d db

refresh:       ## fetch from Kaggle and refresh the database
	python -m pipeline.run

test:          ## needs TEST_DATABASE_URL pointing at a scratch database
	pytest -q
