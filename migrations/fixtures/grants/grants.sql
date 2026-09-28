-- Fixture only, standing in for riftal-game's lib/resources/sql/grants.sql.
-- It depends on the good/ fixtures having created widgets.
CREATE ROLE IF NOT EXISTS riftal_role_mines;
GRANT SELECT ON widgets TO riftal_role_mines;
