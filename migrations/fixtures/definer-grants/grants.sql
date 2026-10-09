-- Fixture only, standing in for riftal-game's lib/resources/sql/grants.sql.
-- It depends on the definer/ fixture having created tallies and tallies_bump.
-- No UPDATE: the role reaches the table only through the procedure.
CREATE ROLE IF NOT EXISTS riftal_role_tally;
GRANT SELECT ON tallies TO riftal_role_tally;
GRANT EXECUTE ON PROCEDURE tallies_bump TO riftal_role_tally;
