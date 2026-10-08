-- Fixture only, the definer-grants/ file with a grant ahead of EXECUTE on
-- gizmos, a table regrant/'s broken 0003 stands in for creating. It errors on
-- any run where 0003 failed, and EXECUTE must still be granted after it.
CREATE ROLE IF NOT EXISTS riftal_role_tally;
GRANT SELECT ON gizmos TO riftal_role_tally;
GRANT SELECT ON tallies TO riftal_role_tally;
GRANT EXECUTE ON PROCEDURE tallies_bump TO riftal_role_tally;
