<%@ page language="java"
         contentType="application/json; charset=UTF-8"
         pageEncoding="UTF-8"
         trimDirectiveWhitespaces="true"%>
<%@ page import="java.sql.*,java.util.*,java.io.*,javax.sql.DataSource,javax.naming.InitialContext,javax.naming.NamingException,javax.naming.directory.*,javax.naming.ldap.*,javax.servlet.http.*,java.text.SimpleDateFormat,java.util.Base64"%>
<%!
/*
 * wsodbbridge.jsp - Oracle + LDAP bridge for WSO2 IS 5.10
 * NO third-party JARs required - pure JDK + Servlet API only.
 * JSON is built with StringBuilder - zero classpath dependencies.
 * Token check DISABLED - open access (restrict at network/firewall level).
 */

    /* === JDBC credentials === */
    private static final String ORA_URL    = "jdbc:oracle:thin:@idnt01cic.paaet.edu.kw:1521:iddb";
    private static final String ORA_USER_C = "ethosdb";
    private static final String ORA_PASS_C = "u_pick_it";
    private static final String ORA_USER_S = "ethosreg";
    private static final String ORA_PASS_S = "u_pick_it";
    private static final String ORA_USER_I = "ethosmet";
    private static final String ORA_PASS_I = "u_pick_it";
    private static final String ORA_DRIVER = "oracle.jdbc.driver.OracleDriver";

    /* === LDAP defaults === */
    private static final String LDAP_URL  = "ldap://PAAET.edu:389";
    private static final String LDAP_BIND = "CN=ethos SSO,OU=Service Accounts,OU=Service Admins,DC=paaet,DC=edu";
    private static final String LDAP_PASS = "P@@et@321";
    private static final String LDAP_BASE = "DC=paaet,DC=edu";

    static {
        try { Class.forName(ORA_DRIVER); } catch (Exception e) { /* pre-loaded */ }
    }

    /* --------------------------------------------------------
     * JSON helpers - no external library needed
     * -------------------------------------------------------- */

    private static String jStr(String s) {
        if (s == null) return "null";
        return "\"" + s.replace("\\","\\\\").replace("\"","\\\"")
                       .replace("\n","\\n").replace("\r","\\r")
                       .replace("\t","\\t") + "\"";
    }
    private static String jBool(boolean b) { return b ? "true" : "false"; }
    private static String jNum(long n)     { return Long.toString(n); }
    private static String jNum(double d)   { return Double.toString(d); }

    private static String ok(String body) {
        return "{\"success\":true," + body + "}";
    }
    private static String fail(String msg) {
        return "{\"success\":false,\"error\":" + jStr(msg) + "}";
    }

    /* --------------------------------------------------------
     * Connection helpers
     * -------------------------------------------------------- */

    private Connection getConn(String dsKey, String cu, String cuser, String cpass)
            throws SQLException {
        String jndi = null, url = ORA_URL, user, pass;
        switch (dsKey == null ? "carbon" : dsKey.toLowerCase()) {
            case "shared":
                jndi = "jdbc/SHARED_DB"; user = ORA_USER_S; pass = ORA_PASS_S; break;
            case "identity":
                jndi = "jdbc/WSO2IdentityDB"; user = ORA_USER_I; pass = ORA_PASS_I; break;
            case "direct":
                if (cu != null && !cu.isEmpty()) return DriverManager.getConnection(cu, cuser, cpass);
            default:
                jndi = "jdbc/WSO2CarbonDB"; user = ORA_USER_C; pass = ORA_PASS_C; break;
        }
        try {
            InitialContext ic = new InitialContext(); DataSource ds = null;
            try { ds = (DataSource) ic.lookup(jndi); }
            catch (NamingException n1) {
                try { ds = (DataSource) ic.lookup("java:comp/env/" + jndi); }
                catch (NamingException n2) { /* ignore */ }
            }
            if (ds != null) return ds.getConnection();
        } catch (Exception ignore) { }
        return DriverManager.getConnection(url, user, pass);
    }

    private void close(AutoCloseable... cs) {
        for (AutoCloseable c : cs) try { if (c != null) c.close(); } catch (Exception e) { /* ignore */ }
    }

    /* --------------------------------------------------------
     * Core query runners
     * -------------------------------------------------------- */

    private static String fmtObj(Object v, SimpleDateFormat sdf) {
        if (v == null) return "null";
        try {
            if (v instanceof Clob) {
                Clob c = (Clob) v;
                return jStr(c.getSubString(1, (int) Math.min(c.length(), 65535)));
            }
            if (v instanceof Blob) return jStr("[BLOB " + ((Blob) v).length() + " bytes]");
            if (v instanceof java.sql.Timestamp || v instanceof java.sql.Date)
                return jStr(sdf.format(v));
        } catch (Exception e) { /* fall through */ }
        return jStr(v.toString());
    }

    /** Rows as arrays */
    private String runQuery(Connection conn, String sql, int maxRows) throws Exception {
        PreparedStatement ps = null; ResultSet rs = null;
        try {
            ps = conn.prepareStatement(sql);
            ps.setFetchSize(200); if (maxRows > 0) ps.setMaxRows(maxRows);
            rs = ps.executeQuery();
            ResultSetMetaData md = rs.getMetaData(); int cc = md.getColumnCount();
            SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
            StringBuilder cols = new StringBuilder("[");
            for (int i = 1; i <= cc; i++) {
                if (i > 1) cols.append(",");
                cols.append(jStr(md.getColumnName(i)));
            }
            cols.append("]");
            StringBuilder rows = new StringBuilder("[");
            boolean first = true; int cnt = 0;
            while (rs.next() && (maxRows <= 0 || cnt++ < maxRows)) {
                if (!first) rows.append(","); first = false;
                rows.append("[");
                for (int i = 1; i <= cc; i++) {
                    if (i > 1) rows.append(",");
                    rows.append(fmtObj(rs.getObject(i), sdf));
                }
                rows.append("]");
            }
            rows.append("]");
            return ok("\"columns\":" + cols + ",\"rows\":" + rows + ",\"rowCount\":" + cnt);
        } finally { close(rs, ps); }
    }

    /** Rows as objects (column name keys), with named params */
    private String runQueryPS(Connection conn, String sql, int maxRows, Object... args) throws Exception {
        PreparedStatement ps = null; ResultSet rs = null;
        try {
            ps = conn.prepareStatement(sql);
            ps.setFetchSize(200); if (maxRows > 0) ps.setMaxRows(maxRows);
            for (int i = 0; i < args.length; i++) ps.setObject(i + 1, args[i]);
            rs = ps.executeQuery();
            ResultSetMetaData md = rs.getMetaData(); int cc = md.getColumnCount();
            SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
            StringBuilder cols = new StringBuilder("[");
            for (int i = 1; i <= cc; i++) {
                if (i > 1) cols.append(",");
                cols.append("{\"name\":").append(jStr(md.getColumnName(i)))
                    .append(",\"type\":").append(jStr(md.getColumnTypeName(i))).append("}");
            }
            cols.append("]");
            StringBuilder rows = new StringBuilder("[");
            boolean first = true; int cnt = 0;
            while (rs.next() && (maxRows <= 0 || cnt++ < maxRows)) {
                if (!first) rows.append(","); first = false;
                rows.append("{");
                for (int i = 1; i <= cc; i++) {
                    if (i > 1) rows.append(",");
                    rows.append(jStr(md.getColumnName(i))).append(":")
                        .append(fmtObj(rs.getObject(i), sdf));
                }
                rows.append("}");
            }
            rows.append("]");
            return ok("\"columns\":" + cols + ",\"rows\":" + rows + ",\"rowCount\":" + cnt);
        } finally { close(rs, ps); }
    }

    /* --------------------------------------------------------
     * Oracle actions
     * -------------------------------------------------------- */

    private String oraCheckConn(Connection c) throws Exception {
        Statement st = null; ResultSet rs = null;
        try {
            st = c.createStatement();
            rs = st.executeQuery("SELECT SYS_CONTEXT('USERENV','DB_NAME'),"
                + "SYS_CONTEXT('USERENV','SESSION_USER'),"
                + "SYS_CONTEXT('USERENV','SERVER_HOST') FROM DUAL");
            if (rs.next())
                return ok("\"db\":" + jStr(rs.getString(1))
                    + ",\"user\":" + jStr(rs.getString(2))
                    + ",\"host\":" + jStr(rs.getString(3))
                    + ",\"message\":\"Connected\"");
            return fail("No row from DUAL");
        } finally { close(rs, st); }
    }

    private String oraSchemas(Connection c) throws Exception {
        return runQueryPS(c,
            "SELECT DISTINCT owner AS SCHEMA_NAME,"
            + "(SELECT COUNT(*) FROM all_objects o2 WHERE o2.owner=ao.owner AND o2.object_type='TABLE') TABLE_COUNT"
            + " FROM all_objects ao ORDER BY owner", 500);
    }

    private String oraTables(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT t.table_name,t.num_rows,t.last_analyzed,t.tablespace_name,cm.comments"
            + " FROM all_tables t LEFT JOIN all_tab_comments cm"
            + " ON cm.owner=t.owner AND cm.table_name=t.table_name"
            + " WHERE t.owner=? ORDER BY t.table_name", 2000, s.toUpperCase());
    }

    private String oraViews(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT view_name,text_length FROM all_views WHERE owner=? ORDER BY view_name",
            2000, s.toUpperCase());
    }

    private String oraCols(Connection c, String s, String t) throws Exception {
        return runQueryPS(c,
            "SELECT c.column_name,c.data_type,c.data_length,c.data_precision,c.data_scale,"
            + "c.nullable,c.data_default,c.column_id,cc.comments"
            + " FROM all_tab_columns c LEFT JOIN all_col_comments cc"
            + " ON cc.owner=c.owner AND cc.table_name=c.table_name AND cc.column_name=c.column_name"
            + " WHERE c.owner=? AND c.table_name=? ORDER BY c.column_id",
            500, s.toUpperCase(), t.toUpperCase());
    }

    private String oraData(Connection c, String s, String t,
            int page, int pageSize, String fc, String fv, String oc, String od) throws Exception {
        page = Math.max(1, page);
        pageSize = (pageSize <= 0 || pageSize > 1000) ? 200 : pageSize;
        int start = (page - 1) * pageSize, end = page * pageSize;
        StringBuilder sb = new StringBuilder();
        sb.append("SELECT * FROM (SELECT a.*,ROWNUM rn FROM (SELECT * FROM \"")
          .append(s.toUpperCase()).append("\".\"").append(t.toUpperCase()).append("\"");
        if (fc != null && !fc.isEmpty() && fv != null && !fv.isEmpty())
            sb.append(" WHERE UPPER(\"").append(fc).append("\") LIKE UPPER('%")
              .append(fv.replace("'","''")).append("%')");
        if (oc != null && !oc.isEmpty())
            sb.append(" ORDER BY \"").append(oc).append("\"")
              .append("DESC".equalsIgnoreCase(od) ? " DESC" : " ASC");
        sb.append(") a WHERE ROWNUM<=").append(end).append(") WHERE rn>").append(start);
        return runQuery(c, sb.toString(), pageSize);
    }

    private String oraRowCount(Connection c, String s, String t) throws Exception {
        Statement st = null; ResultSet rs = null;
        try {
            st = c.createStatement();
            rs = st.executeQuery("SELECT COUNT(*) FROM \""
                + s.toUpperCase() + "\".\"" + t.toUpperCase() + "\"");
            long n = rs.next() ? rs.getLong(1) : 0L;
            return ok("\"rowCount\":" + n);
        } finally { close(rs, st); }
    }

    private String oraDDL(Connection c, String s, String ot, String on) throws Exception {
        Statement st = null; ResultSet rs = null;
        try {
            st = c.createStatement();
            rs = st.executeQuery("SELECT DBMS_METADATA.GET_DDL('"
                + ot.toUpperCase() + "','" + on.toUpperCase() + "','" + s.toUpperCase() + "') FROM DUAL");
            if (rs.next()) {
                Object v = rs.getObject(1);
                String ddl = (v instanceof Clob)
                    ? ((Clob) v).getSubString(1, (int) Math.min(((Clob) v).length(), 200000))
                    : v.toString();
                return ok("\"ddl\":" + jStr(ddl));
            }
            return fail("No DDL returned");
        } finally { close(rs, st); }
    }

    private String oraObjSrc(Connection c, String s, String ot, String on) throws Exception {
        String res = runQueryPS(c,
            "SELECT line,text FROM all_source WHERE owner=? AND name=? AND type=? ORDER BY line",
            50000, s.toUpperCase(), on.toUpperCase(), ot.toUpperCase());
        return res; /* caller will get rows; source concat is left to client */
    }

    private String oraConstraints(Connection c, String s, String t) throws Exception {
        return runQueryPS(c,
            "SELECT c.constraint_name,c.constraint_type,c.status,c.search_condition,"
            + "c.r_owner,c.r_constraint_name,c.delete_rule,"
            + "LISTAGG(cc.column_name,',') WITHIN GROUP (ORDER BY cc.position) AS columns"
            + " FROM all_constraints c JOIN all_cons_columns cc"
            + " ON cc.owner=c.owner AND cc.constraint_name=c.constraint_name"
            + " WHERE c.owner=? AND c.table_name=?"
            + " GROUP BY c.constraint_name,c.constraint_type,c.status,c.search_condition,"
            + "c.r_owner,c.r_constraint_name,c.delete_rule ORDER BY c.constraint_type",
            500, s.toUpperCase(), t.toUpperCase());
    }

    private String oraIndexes(Connection c, String s, String t) throws Exception {
        return runQueryPS(c,
            "SELECT i.index_name,i.index_type,i.uniqueness,i.status,i.partitioned,"
            + "LISTAGG(ic.column_name,',') WITHIN GROUP (ORDER BY ic.column_position) AS columns"
            + " FROM all_indexes i JOIN all_ind_columns ic"
            + " ON ic.index_owner=i.owner AND ic.index_name=i.index_name"
            + " WHERE i.owner=? AND i.table_name=?"
            + " GROUP BY i.index_name,i.index_type,i.uniqueness,i.status,i.partitioned",
            500, s.toUpperCase(), t.toUpperCase());
    }

    private String oraTableStats(Connection c, String s, String t) throws Exception {
        return runQueryPS(c,
            "SELECT num_rows,blocks,avg_row_len,sample_size,last_analyzed,"
            + "row_movement,compression,compress_for FROM all_tables WHERE owner=? AND table_name=?",
            1, s.toUpperCase(), t.toUpperCase());
    }

    private String oraPartitions(Connection c, String s, String t) throws Exception {
        return runQueryPS(c,
            "SELECT partition_name,partition_position,high_value,num_rows,tablespace_name,last_analyzed"
            + " FROM all_tab_partitions WHERE table_owner=? AND table_name=? ORDER BY partition_position",
            500, s.toUpperCase(), t.toUpperCase());
    }

    private String oraSequences(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT sequence_name,min_value,max_value,increment_by,cycle_flag,order_flag,cache_size,last_number"
            + " FROM all_sequences WHERE sequence_owner=? ORDER BY sequence_name",
            2000, s.toUpperCase());
    }

    private String oraTriggers(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT trigger_name,trigger_type,triggering_event,table_name,status,description"
            + " FROM all_triggers WHERE owner=? ORDER BY trigger_name", 2000, s.toUpperCase());
    }

    private String oraProcedures(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT object_name,object_type,status,created,last_ddl_time FROM all_objects"
            + " WHERE owner=? AND object_type IN ('PROCEDURE','FUNCTION','PACKAGE','PACKAGE BODY')"
            + " ORDER BY object_type,object_name", 2000, s.toUpperCase());
    }

    private String oraSynonyms(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT synonym_name,table_owner,table_name,db_link FROM all_synonyms"
            + " WHERE owner=? ORDER BY synonym_name", 2000, s.toUpperCase());
    }

    private String oraDbLinks(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT owner,db_link,username,host,created FROM all_db_links"
            + " WHERE owner=? ORDER BY db_link", 500, s.toUpperCase());
    }

    private String oraMviews(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT mview_name,refresh_method,refresh_mode,last_refresh_date,staleness,query"
            + " FROM all_mviews WHERE owner=? ORDER BY mview_name", 2000, s.toUpperCase());
    }

    private String oraTypes(Connection c, String s) throws Exception {
        return runQueryPS(c,
            "SELECT type_name,typecode,attributes,methods FROM all_types"
            + " WHERE owner=? ORDER BY type_name", 2000, s.toUpperCase());
    }

    private String oraObjects(Connection c, String s, String ot) throws Exception {
        return runQueryPS(c,
            "SELECT object_name,object_type,status,created,last_ddl_time FROM all_objects"
            + " WHERE owner=? AND object_type=? ORDER BY object_name",
            5000, s.toUpperCase(), ot.toUpperCase());
    }

    private String oraExecQuery(Connection c, String sql, int max) throws Exception {
        if (max <= 0) max = 500;
        return runQuery(c, sql, max);
    }

    private String oraExecNonQuery(Connection c, String sql) throws Exception {
        Statement st = null;
        try {
            c.setAutoCommit(false); st = c.createStatement();
            int n = st.executeUpdate(sql); c.commit();
            return ok("\"rowsAffected\":" + n + ",\"message\":\"OK, rows affected: " + n + "\"");
        } catch (Exception e) {
            try { c.rollback(); } catch (Exception ignore) { }
            return fail(e.getMessage());
        } finally {
            try { c.setAutoCommit(true); } catch (Exception ignore) { }
            close(st);
        }
    }

    private String oraExplain(Connection c, String sql) throws Exception {
        Statement st = null; ResultSet rs = null;
        try {
            st = c.createStatement(); st.execute("EXPLAIN PLAN FOR " + sql);
            rs = st.executeQuery("SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE',NULL,'ALL'))");
            StringBuilder sb = new StringBuilder("[");
            boolean first = true;
            while (rs.next()) {
                if (!first) sb.append(","); first = false;
                sb.append(jStr(rs.getString(1)));
            }
            sb.append("]");
            return ok("\"plan\":" + sb);
        } finally { close(rs, st); }
    }

    private String oraDeps(Connection c, String s, String n, String t) throws Exception {
        return runQueryPS(c,
            "SELECT name,type,referenced_owner,referenced_name,referenced_type,dependency_type"
            + " FROM all_dependencies WHERE owner=? AND name=? AND type=?"
            + " ORDER BY referenced_type,referenced_name",
            1000, s.toUpperCase(), n.toUpperCase(), t.toUpperCase());
    }

    private String oraSearch(Connection c, String term) throws Exception {
        return runQueryPS(c,
            "SELECT owner,object_type,object_name,status FROM all_objects"
            + " WHERE UPPER(object_name) LIKE UPPER(?) ORDER BY owner,object_type,object_name",
            500, "%" + term + "%");
    }

    private String oraSessions(Connection c) throws Exception {
        return runQuery(c,
            "SELECT sid,serial#,username,status,machine,program,logon_time,sql_id,event,wait_class"
            + " FROM v$session WHERE type='USER' ORDER BY logon_time DESC", 200);
    }

    private String oraTablespaces(Connection c) throws Exception {
        return runQuery(c,
            "SELECT tablespace_name,status,contents,logging,bigfile"
            + " FROM dba_tablespaces ORDER BY tablespace_name", 200);
    }

    private String oraLob(Connection c, String s, String t, String col, String where) throws Exception {
        Statement st = null; ResultSet rs = null;
        try {
            st = c.createStatement();
            rs = st.executeQuery("SELECT \"" + col + "\" FROM \""
                + s.toUpperCase() + "\".\"" + t.toUpperCase() + "\" WHERE " + where);
            if (!rs.next()) return fail("No row found");
            Object v = rs.getObject(1);
            if (v instanceof Clob) {
                Clob cl = (Clob) v;
                return ok("\"type\":\"CLOB\",\"data\":"
                    + jStr(cl.getSubString(1, (int) Math.min(cl.length(), 500000))));
            }
            if (v instanceof Blob) {
                Blob bl = (Blob) v;
                return ok("\"type\":\"BLOB\",\"lengthBytes\":" + bl.length()
                    + ",\"data\":" + jStr(Base64.getEncoder().encodeToString(
                        bl.getBytes(1, (int) Math.min(bl.length(), 1048576)))));
            }
            return ok("\"type\":\"VARCHAR\",\"data\":" + jStr(v == null ? "" : v.toString()));
        } finally { close(rs, st); }
    }

    private String oraPerf(Connection c) throws Exception {
        Statement st = null; ResultSet rs = null;
        try {
            st = c.createStatement();
            rs = st.executeQuery(
                "SELECT sql_id,sql_text,executions,elapsed_time/1e6 elapsed_sec,"
                + "cpu_time/1e6 cpu_sec,buffer_gets,disk_reads"
                + " FROM v$sql ORDER BY elapsed_time DESC FETCH FIRST 20 ROWS ONLY");
            ResultSetMetaData md = rs.getMetaData();
            SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
            StringBuilder top = new StringBuilder("[");
            boolean first = true;
            while (rs.next()) {
                if (!first) top.append(","); first = false;
                top.append("{");
                for (int i = 1; i <= md.getColumnCount(); i++) {
                    if (i > 1) top.append(",");
                    top.append(jStr(md.getColumnName(i))).append(":")
                       .append(fmtObj(rs.getObject(i), sdf));
                }
                top.append("}");
            }
            top.append("]");
            close(rs);
            rs = st.executeQuery("SELECT COUNT(*) FROM v$session WHERE status='ACTIVE' AND type='USER'");
            int act = rs.next() ? rs.getInt(1) : 0;
            return ok("\"topSql\":" + top + ",\"activeSessions\":" + act);
        } catch (Exception e) { return fail(e.getMessage()); }
        finally { close(rs, st); }
    }

    private String oraStorage(Connection c) throws Exception {
        return runQuery(c,
            "SELECT df.tablespace_name,df.total_mb,fs.free_mb,"
            + "ROUND((df.total_mb-NVL(fs.free_mb,0))/df.total_mb*100,1) pct_used"
            + " FROM (SELECT tablespace_name,ROUND(SUM(bytes)/1048576) total_mb"
            + "       FROM dba_data_files GROUP BY tablespace_name) df"
            + " LEFT JOIN (SELECT tablespace_name,ROUND(SUM(bytes)/1048576) free_mb"
            + "            FROM dba_free_space GROUP BY tablespace_name) fs"
            + " ON df.tablespace_name=fs.tablespace_name ORDER BY df.tablespace_name", 200);
    }

    /* --------------------------------------------------------
     * LDAP actions
     * -------------------------------------------------------- */

    private DirContext ldapCtx(String url, String dn, String pw) throws Exception {
        Hashtable<String,String> env = new Hashtable<String,String>();
        env.put(javax.naming.Context.INITIAL_CONTEXT_FACTORY, "com.sun.jndi.ldap.LdapCtxFactory");
        env.put(javax.naming.Context.PROVIDER_URL, url);
        env.put(javax.naming.Context.SECURITY_AUTHENTICATION, "simple");
        env.put(javax.naming.Context.SECURITY_PRINCIPAL, dn);
        env.put(javax.naming.Context.SECURITY_CREDENTIALS, pw);
        env.put("com.sun.jndi.ldap.connect.timeout", "5000");
        env.put("com.sun.jndi.ldap.read.timeout", "15000");
        env.put(javax.naming.Context.REFERRAL, "ignore");
        return new InitialDirContext(env);
    }

    private String ldapEntryJson(SearchResult sr) throws Exception {
        StringBuilder o = new StringBuilder("{");
        o.append("\"dn\":").append(jStr(sr.getNameInNamespace()));
        Attributes attrs = sr.getAttributes();
        NamingEnumeration<? extends Attribute> ae = attrs.getAll();
        while (ae.hasMore()) {
            Attribute a = ae.next();
            o.append(",").append(jStr(a.getID())).append(":");
            if (a.size() == 1) {
                Object v = a.get();
                o.append(v instanceof byte[]
                    ? jStr(Base64.getEncoder().encodeToString((byte[]) v)) : jStr(v.toString()));
            } else {
                o.append("[");
                NamingEnumeration<?> ne = a.getAll(); boolean first = true;
                while (ne.hasMore()) {
                    if (!first) o.append(","); first = false;
                    Object v = ne.next();
                    o.append(v instanceof byte[]
                        ? jStr(Base64.getEncoder().encodeToString((byte[]) v)) : jStr(v.toString()));
                }
                o.append("]");
            }
        }
        o.append("}");
        return o.toString();
    }

    private String ldapSearch(String url, String dn, String pw,
            String base, String filter, String[] ret, int scope, int max) throws Exception {
        DirContext ctx = null;
        try {
            ctx = ldapCtx(url, dn, pw);
            SearchControls sc = new SearchControls();
            sc.setSearchScope(scope); sc.setCountLimit(max <= 0 ? 200 : max); sc.setTimeLimit(20000);
            if (ret != null && ret.length > 0) sc.setReturningAttributes(ret);
            NamingEnumeration<SearchResult> res = ctx.search(base, filter, sc);
            StringBuilder entries = new StringBuilder("[");
            boolean first = true;
            while (res.hasMore()) {
                try {
                    if (!first) entries.append(","); first = false;
                    entries.append(ldapEntryJson(res.next()));
                } catch (javax.naming.PartialResultException e) { break; }
                  catch (javax.naming.SizeLimitExceededException e) { break; }
            }
            entries.append("]");
            int cnt = entries.toString().split("\\{\"dn\"").length - 1;
            return ok("\"entries\":" + entries + ",\"count\":" + cnt);
        } finally { if (ctx != null) try { ctx.close(); } catch (Exception e) { /* ignore */ } }
    }

    private String ldapCheckConn(String url, String dn, String pw) throws Exception {
        DirContext ctx = null;
        try {
            ctx = ldapCtx(url, dn, pw);
            Attributes attrs = ctx.getAttributes("",
                new String[]{"namingContexts","defaultNamingContext","supportedLDAPVersion"});
            StringBuilder info = new StringBuilder("{");
            NamingEnumeration<? extends Attribute> ae = attrs.getAll(); boolean first = true;
            while (ae.hasMore()) {
                Attribute a = ae.next();
                if (!first) info.append(","); first = false;
                info.append(jStr(a.getID())).append(":");
                if (a.size() == 1) { info.append(jStr(a.get().toString())); }
                else {
                    info.append("["); NamingEnumeration<?> ve = a.getAll(); boolean f2 = true;
                    while (ve.hasMore()) { if (!f2) info.append(","); f2=false; info.append(jStr(ve.next().toString())); }
                    info.append("]");
                }
            }
            info.append("}");
            return ok("\"serverInfo\":" + info + ",\"message\":" + jStr("LDAP connected to " + url));
        } finally { if (ctx != null) try { ctx.close(); } catch (Exception e) { /* ignore */ } }
    }

    private String ldapTree(String url, String dn, String pw, String base, int maxDepth) throws Exception {
        DirContext ctx = null;
        try {
            ctx = ldapCtx(url, dn, pw);
            return ok("\"tree\":" + buildTree(ctx, base, 0, maxDepth <= 0 ? 2 : maxDepth));
        } finally { if (ctx != null) try { ctx.close(); } catch (Exception e) { /* ignore */ } }
    }

    private String buildTree(DirContext ctx, String dn, int depth, int max) throws Exception {
        StringBuilder n = new StringBuilder("{\"dn\":").append(jStr(dn));
        try {
            Attributes attrs = ctx.getAttributes(dn, new String[]{"cn","ou","dc","objectClass"});
            Attribute cnA = attrs.get("cn"); if (cnA != null) n.append(",\"cn\":").append(jStr(cnA.get().toString()));
            Attribute ouA = attrs.get("ou"); if (ouA != null) n.append(",\"ou\":").append(jStr(ouA.get().toString()));
            Attribute ocA = attrs.get("objectClass");
            if (ocA != null) {
                n.append(",\"objectClass\":[");
                NamingEnumeration<?> ne = ocA.getAll(); boolean first = true;
                while (ne.hasMore()) { if (!first) n.append(","); first=false; n.append(jStr(ne.next().toString())); }
                n.append("]");
            }
        } catch (Exception ignore) { }
        if (depth < max) {
            SearchControls sc = new SearchControls();
            sc.setSearchScope(SearchControls.ONELEVEL_SCOPE); sc.setCountLimit(100);
            sc.setReturningAttributes(new String[]{"cn","ou","dc","objectClass"});
            n.append(",\"children\":[");
            boolean first = true;
            try {
                NamingEnumeration<SearchResult> res = ctx.search(dn, "(objectClass=*)", sc);
                while (res.hasMore()) {
                    try {
                        SearchResult sr = res.next();
                        if (!first) n.append(","); first = false;
                        n.append(buildTree(ctx, sr.getNameInNamespace(), depth + 1, max));
                    } catch (Exception ignore) { }
                }
            } catch (Exception ignore) { }
            n.append("]");
        }
        n.append("}");
        return n.toString();
    }

    /* --------------------------------------------------------
     * Request param helpers
     * -------------------------------------------------------- */
    private String p(HttpServletRequest req, String name) {
        String v = req.getParameter(name); return v == null ? "" : v.trim();
    }
    private int pi(HttpServletRequest req, String name, int def) {
        try { return Integer.parseInt(p(req, name)); } catch (Exception e) { return def; }
    }
%>
<%
    response.setContentType("application/json; charset=UTF-8");
    response.setHeader("Cache-Control", "no-cache, no-store");
    response.setHeader("Access-Control-Allow-Origin", "*");
    response.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
    response.setHeader("Access-Control-Allow-Headers", "Content-Type,Authorization");

    if ("OPTIONS".equals(request.getMethod())) { response.setStatus(200); return; }

    String action     = p(request, "action");
    String schema     = p(request, "schema");
    String objectName = p(request, "objectName");
    String objectType = p(request, "objectType");
    String dsKey      = p(request, "ds");
    String customUrl  = p(request, "jdbcUrl");
    String customUser = p(request, "dbUser");
    String customPass = p(request, "dbPass");

    String ldapUrl  = p(request, "ldapUrl");  if (ldapUrl.isEmpty())  ldapUrl  = LDAP_URL;
    String ldapBind = p(request, "ldapBind"); if (ldapBind.isEmpty()) ldapBind = LDAP_BIND;
    String ldapPass = p(request, "ldapPass"); if (ldapPass.isEmpty()) ldapPass = LDAP_PASS;
    String ldapBase = p(request, "ldapBase"); if (ldapBase.isEmpty()) ldapBase = LDAP_BASE;

    String result = null;

    if (action.isEmpty()) {
        result = "{\"success\":false,\"error\":\"Missing action\","
            + "\"oracleActions\":[\"checkConnection\",\"getSchemas\",\"getTables\",\"getViews\","
            + "\"getTableColumns\",\"getTableData\",\"getRowCount\",\"getDDL\",\"getObjectSource\","
            + "\"getConstraints\",\"getIndexes\",\"getTableStats\",\"getPartitions\",\"getSequences\","
            + "\"getTriggers\",\"getProcedures\",\"getSynonyms\",\"getDbLinks\",\"getMaterializedViews\","
            + "\"getTypes\",\"getDatabaseObjects\",\"executeQuery\",\"executeNonQuery\",\"explainPlan\","
            + "\"getDependencies\",\"search\",\"getSessionInfo\",\"getTablespaces\","
            + "\"getLobData\",\"getPerformance\",\"getStorageInfo\"],"
            + "\"ldapActions\":[\"ldapCheckConnection\",\"ldapSearch\",\"ldapGetUsers\","
            + "\"ldapGetGroups\",\"ldapGetOUs\",\"ldapGetTree\",\"ldapGetEntry\"]}";
        out.print(result);
        return;
    }

    try {
        /* LDAP branch */
        if (action.startsWith("ldap")) {
            switch (action) {
                case "ldapCheckConnection":
                    result = ldapCheckConn(ldapUrl, ldapBind, ldapPass); break;
                case "ldapSearch": {
                    String f = p(request,"filter"); if (f.isEmpty()) f = "(objectClass=*)";
                    String as = p(request,"attrs");
                    String[] att = as.isEmpty() ? null : as.split(",");
                    result = ldapSearch(ldapUrl, ldapBind, ldapPass, ldapBase, f, att,
                        pi(request,"scope", SearchControls.SUBTREE_SCOPE),
                        pi(request,"maxResults", 200));
                    break;
                }
                case "ldapGetUsers": {
                    String f = p(request,"filter"); if (f.isEmpty()) f = "(objectClass=user)";
                    result = ldapSearch(ldapUrl, ldapBind, ldapPass, ldapBase, f,
                        new String[]{"sAMAccountName","displayName","mail","memberOf",
                                     "userAccountControl","whenCreated","lastLogon"},
                        SearchControls.SUBTREE_SCOPE, pi(request,"maxResults", 200));
                    break;
                }
                case "ldapGetGroups": {
                    String f = p(request,"filter"); if (f.isEmpty()) f = "(objectClass=group)";
                    result = ldapSearch(ldapUrl, ldapBind, ldapPass, ldapBase, f,
                        new String[]{"cn","description","member","groupType","distinguishedName"},
                        SearchControls.SUBTREE_SCOPE, pi(request,"maxResults", 200));
                    break;
                }
                case "ldapGetOUs":
                    result = ldapSearch(ldapUrl, ldapBind, ldapPass, ldapBase,
                        "(objectClass=organizationalUnit)",
                        new String[]{"ou","description","distinguishedName"},
                        SearchControls.SUBTREE_SCOPE, pi(request,"maxResults", 500));
                    break;
                case "ldapGetTree": {
                    String b = p(request,"baseDN"); if (b.isEmpty()) b = ldapBase;
                    result = ldapTree(ldapUrl, ldapBind, ldapPass, b, pi(request,"depth", 2));
                    break;
                }
                case "ldapGetEntry": {
                    String dn = p(request,"dn");
                    if (dn.isEmpty()) { result = fail("dn required"); break; }
                    result = ldapSearch(ldapUrl, ldapBind, ldapPass, dn, "(objectClass=*)",
                        null, SearchControls.OBJECT_SCOPE, 1);
                    break;
                }
                default: result = fail("Unknown LDAP action: " + action);
            }
            out.print(result);
            return;
        }

        /* Oracle branch */
        Connection conn = null;
        try {
            conn = getConn(dsKey, customUrl, customUser, customPass);
            switch (action) {
                case "checkConnection":      result = oraCheckConn(conn); break;
                case "getSchemas":           result = oraSchemas(conn); break;
                case "getTables":            result = oraTables(conn, schema); break;
                case "getViews":             result = oraViews(conn, schema); break;
                case "getTableColumns":      result = oraCols(conn, schema, objectName); break;
                case "getTableData":
                    result = oraData(conn, schema, objectName,
                        pi(request,"page",1), pi(request,"pageSize",200),
                        p(request,"filterCol"), p(request,"filterVal"),
                        p(request,"orderCol"), p(request,"orderDir"));
                    break;
                case "getRowCount":          result = oraRowCount(conn, schema, objectName); break;
                case "getDDL":
                    result = oraDDL(conn, schema,
                        objectType.isEmpty() ? "TABLE" : objectType, objectName); break;
                case "getObjectSource":      result = oraObjSrc(conn, schema, objectType, objectName); break;
                case "getConstraints":       result = oraConstraints(conn, schema, objectName); break;
                case "getIndexes":           result = oraIndexes(conn, schema, objectName); break;
                case "getTableStats":        result = oraTableStats(conn, schema, objectName); break;
                case "getPartitions":        result = oraPartitions(conn, schema, objectName); break;
                case "getSequences":         result = oraSequences(conn, schema); break;
                case "getTriggers":          result = oraTriggers(conn, schema); break;
                case "getProcedures":        result = oraProcedures(conn, schema); break;
                case "getSynonyms":          result = oraSynonyms(conn, schema); break;
                case "getDbLinks":           result = oraDbLinks(conn, schema); break;
                case "getMaterializedViews": result = oraMviews(conn, schema); break;
                case "getTypes":             result = oraTypes(conn, schema); break;
                case "getDatabaseObjects":   result = oraObjects(conn, schema, objectType); break;
                case "executeQuery": {
                    String sql = p(request,"query"); if (sql.isEmpty()) sql = p(request,"sql");
                    result = oraExecQuery(conn, sql, pi(request,"maxRows",500)); break;
                }
                case "executeNonQuery": {
                    String sql = p(request,"sql"); if (sql.isEmpty()) sql = p(request,"query");
                    result = oraExecNonQuery(conn, sql); break;
                }
                case "explainPlan": {
                    String sql = p(request,"query"); if (sql.isEmpty()) sql = p(request,"sql");
                    result = oraExplain(conn, sql); break;
                }
                case "getDependencies":
                    result = oraDeps(conn, schema, objectName, objectType); break;
                case "search":
                    result = oraSearch(conn, p(request,"term")); break;
                case "getSessionInfo":
                    result = oraSessions(conn); break;
                case "getTablespaces":
                    result = oraTablespaces(conn); break;
                case "getLobData":
                    result = oraLob(conn, schema, objectName,
                        p(request,"column"), p(request,"where")); break;
                case "getPerformance":
                    result = oraPerf(conn); break;
                case "getStorageInfo":
                    result = oraStorage(conn); break;
                default:
                    result = fail("Unknown action: " + action);
            }
        } finally { close(conn); }

    } catch (Exception ex) {
        StringBuilder trace = new StringBuilder("[");
        StackTraceElement[] st = ex.getStackTrace();
        for (int i = 0; i < Math.min(st.length, 4); i++) {
            if (i > 0) trace.append(",");
            trace.append(jStr(st[i].toString()));
        }
        trace.append("]");
        result = "{\"success\":false,\"error\":"
            + jStr(ex.getClass().getSimpleName() + ": " + ex.getMessage())
            + ",\"trace\":" + trace + "}";
    }

    out.print(result);
%>
