<%@ page language="java" contentType="application/json; charset=UTF-8" pageEncoding="UTF-8"
    trimDirectiveWhitespaces="true"%>
<%@ page import="
    java.sql.*,
    java.util.*,
    java.io.*,
    javax.sql.DataSource,
    javax.naming.InitialContext,
    javax.naming.NamingException,
    javax.naming.directory.*,
    javax.naming.ldap.*,
    javax.servlet.http.*,
    java.text.SimpleDateFormat,
    java.util.Base64,
    com.fasterxml.jackson.databind.ObjectMapper,
    com.fasterxml.jackson.databind.node.ObjectNode,
    com.fasterxml.jackson.databind.node.ArrayNode,
    com.fasterxml.jackson.databind.JsonNode
"%>
<%!
/* =====================================================================
wsodbbridge.jsp  –  Oracle + LDAP management bridge for WSO2 IS 5.10
Deploy to: /repository/deployment/server/webapps/authenticationendpoint/
URL:       https://<host>:9443/authenticationendpoint/wsodbbridge.jsp?token=<TOKEN>&action=...
Uses Jackson (already on WSO2 classpath) – no extra JARs needed.
===================================================================== */

 private static final ObjectMapper MAPPER = new ObjectMapper();

 // ?? Security token ????????????????????????????????????????????????????
 private static final String ACCESS_TOKEN = "WSO2Mgr@Bridge#2024";

 // ?? Direct JDBC fallback credentials ?????????????????????????????????
 private static final String ORA_URL_CARBON   = "jdbc:oracle:thin:@idnt01cic.paaet.edu.kw:1521:iddb";
 private static final String ORA_URL_SHARED   = "jdbc:oracle:thin:@idnt01cic.paaet.edu.kw:1521:iddb";
 private static final String ORA_URL_IDENTITY = "jdbc:oracle:thin:@idnt01cic.paaet.edu.kw:1521:iddb";
 private static final String ORA_USER_CARBON   = "ethosdb";
 private static final String ORA_USER_SHARED   = "ethosreg";
 private static final String ORA_USER_IDENTITY = "ethosmet";
 private static final String ORA_PASS_CARBON   = "u_pick_it";
 private static final String ORA_PASS_SHARED   = "u_pick_it";
 private static final String ORA_PASS_IDENTITY = "u_pick_it";
 private static final String ORA_DRIVER = "oracle.jdbc.driver.OracleDriver";

 // ?? LDAP ??????????????????????????????????????????????????????????????
 private static final String LDAP_URL  = "ldap://PAAET.edu:389";
 private static final String LDAP_BIND = "CN=ethos SSO,OU=Service Accounts,OU=Service Admins,DC=paaet,DC=edu";
 private static final String LDAP_PASS = "P@@et@321";
 private static final String LDAP_BASE = "DC=paaet,DC=edu";

 static {
     try { Class.forName(ORA_DRIVER); } catch (Exception e) { /* pre-loaded by WSO2 */ }
 }

 // ?? helpers ???????????????????????????????????????????????????????????
 private ObjectNode obj()  { return MAPPER.createObjectNode(); }
 private ArrayNode  arr()  { return MAPPER.createArrayNode();  }
 private ObjectNode err(String msg) { ObjectNode n=obj(); n.put("success",false); n.put("error",msg); return n; }

 private Connection getConnection(String dsKey, String customUrl, String customUser, String customPass)
         throws SQLException {
     String jndiName=null, fallbackUrl=null, fallbackUser=null, fallbackPass=null;
     switch (dsKey==null?"carbon":dsKey.toLowerCase()) {
         case "shared":
             jndiName="jdbc/SHARED_DB";
             fallbackUrl=ORA_URL_SHARED; fallbackUser=ORA_USER_SHARED; fallbackPass=ORA_PASS_SHARED; break;
         case "identity":
             jndiName="jdbc/WSO2IdentityDB";
             fallbackUrl=ORA_URL_IDENTITY; fallbackUser=ORA_USER_IDENTITY; fallbackPass=ORA_PASS_IDENTITY; break;
         case "direct":
             if (customUrl!=null && !customUrl.isEmpty())
                 return DriverManager.getConnection(customUrl, customUser, customPass);
         default:
             jndiName="jdbc/WSO2CarbonDB";
             fallbackUrl=ORA_URL_CARBON; fallbackUser=ORA_USER_CARBON; fallbackPass=ORA_PASS_CARBON; break;
     }
     try {
         InitialContext ctx=new InitialContext(); DataSource ds=null;
         try { ds=(DataSource)ctx.lookup(jndiName); }
         catch (NamingException e1) {
             try { ds=(DataSource)ctx.lookup("java:comp/env/"+jndiName); } catch (NamingException e2) {}
         }
         if (ds!=null) return ds.getConnection();
     } catch (Exception ignore) {}
     return DriverManager.getConnection(fallbackUrl, fallbackUser, fallbackPass);
 }

 private void close(AutoCloseable... cs) {
     for (AutoCloseable c:cs) try { if(c!=null) c.close(); } catch (Exception ignore) {}
 }

 private String fmtVal(Object v, SimpleDateFormat sdf) throws Exception {
     if (v==null) return null;
     if (v instanceof Clob) { Clob c=(Clob)v; return c.getSubString(1,(int)Math.min(c.length(),65535)); }
     if (v instanceof Blob) return "[BLOB "+((Blob)v).length()+" bytes]";
     if (v instanceof java.sql.Timestamp || v instanceof java.sql.Date) return sdf.format(v);
     return v.toString();
 }

 /** Generic query – rows as arrays, columns as plain strings */
 private ObjectNode runQuery(Connection conn, String sql, int maxRows) throws Exception {
     ObjectNode r=obj(); PreparedStatement ps=null; ResultSet rs=null;
     try {
         ps=conn.prepareStatement(sql);
         ps.setFetchSize(200); if(maxRows>0) ps.setMaxRows(maxRows);
         rs=ps.executeQuery();
         ResultSetMetaData md=rs.getMetaData(); int cc=md.getColumnCount();
         ArrayNode cols=arr();
         for(int i=1;i<=cc;i++) cols.add(md.getColumnName(i));
         r.set("columns",cols);
         ArrayNode rows=arr(); SimpleDateFormat sdf=new SimpleDateFormat("yyyy-MM-dd HH:mm:ss"); int cnt=0;
         while(rs.next()&&(maxRows<=0||cnt++<maxRows)){
             ArrayNode row=arr();
             for(int i=1;i<=cc;i++){String v=fmtVal(rs.getObject(i),sdf); if(v==null)row.addNull(); else row.add(v);}
             rows.add(row);
         }
         r.set("rows",rows); r.put("rowCount",rows.size()); r.put("success",true);
     } finally { close(rs,ps); }
     return r;
 }

 /** Parameterised query – rows as objects keyed by column name */
 private ObjectNode runQueryPS(Connection conn, String sql, int maxRows, Object... args) throws Exception {
     ObjectNode r=obj(); PreparedStatement ps=null; ResultSet rs=null;
     try {
         ps=conn.prepareStatement(sql);
         ps.setFetchSize(200); if(maxRows>0) ps.setMaxRows(maxRows);
         for(int i=0;i<args.length;i++) ps.setObject(i+1,args[i]);
         rs=ps.executeQuery();
         ResultSetMetaData md=rs.getMetaData(); int cc=md.getColumnCount();
         ArrayNode cols=arr();
         for(int i=1;i<=cc;i++){ObjectNode col=obj();col.put("name",md.getColumnName(i));col.put("type",md.getColumnTypeName(i));cols.add(col);}
         r.set("columns",cols);
         ArrayNode rows=arr(); SimpleDateFormat sdf=new SimpleDateFormat("yyyy-MM-dd HH:mm:ss"); int cnt=0;
         while(rs.next()&&(maxRows<=0||cnt++<maxRows)){
             ObjectNode row=obj();
             for(int i=1;i<=cc;i++){String cn=md.getColumnName(i);String v=fmtVal(rs.getObject(i),sdf);if(v==null)row.putNull(cn);else row.put(cn,v);}
             rows.add(row);
         }
         r.set("rows",rows); r.put("rowCount",rows.size()); r.put("success",true);
     } finally { close(rs,ps); }
     return r;
 }

 // ?? Oracle actions ????????????????????????????????????????????????????

 private ObjectNode oraCheckConnection(Connection conn) throws Exception {
     ObjectNode r=obj(); Statement st=null; ResultSet rs=null;
     try {
         st=conn.createStatement();
         rs=st.executeQuery("SELECT SYS_CONTEXT('USERENV','DB_NAME'),SYS_CONTEXT('USERENV','SESSION_USER'),SYS_CONTEXT('USERENV','SERVER_HOST') FROM DUAL");
         if(rs.next()){r.put("db",rs.getString(1));r.put("user",rs.getString(2));r.put("host",rs.getString(3));}
         r.put("success",true); r.put("message","Connected");
     } finally { close(rs,st); }
     return r;
 }

 private ObjectNode oraGetSchemas(Connection conn) throws Exception {
     return runQueryPS(conn,
         "SELECT DISTINCT owner AS SCHEMA_NAME,(SELECT COUNT(*) FROM all_objects o2 WHERE o2.owner=ao.owner AND o2.object_type='TABLE') TABLE_COUNT FROM all_objects ao ORDER BY owner",500);
 }
 private ObjectNode oraGetTables(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT t.table_name,t.num_rows,t.last_analyzed,t.tablespace_name,c.comments FROM all_tables t LEFT JOIN all_tab_comments c ON c.owner=t.owner AND c.table_name=t.table_name WHERE t.owner=? ORDER BY t.table_name",2000,schema.toUpperCase());
 }
 private ObjectNode oraGetViews(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT view_name,text_length FROM all_views WHERE owner=? ORDER BY view_name",2000,schema.toUpperCase());
 }
 private ObjectNode oraGetTableColumns(Connection conn,String schema,String table) throws Exception {
     return runQueryPS(conn,
         "SELECT c.column_name,c.data_type,c.data_length,c.data_precision,c.data_scale,c.nullable,c.data_default,c.column_id,cc.comments "+
         "FROM all_tab_columns c LEFT JOIN all_col_comments cc ON cc.owner=c.owner AND cc.table_name=c.table_name AND cc.column_name=c.column_name "+
         "WHERE c.owner=? AND c.table_name=? ORDER BY c.column_id",500,schema.toUpperCase(),table.toUpperCase());
 }

 private ObjectNode oraGetTableData(Connection conn,String schema,String table,
         int page,int pageSize,String filterCol,String filterVal,String orderCol,String orderDir) throws Exception {
     page=Math.max(1,page); pageSize=(pageSize<=0||pageSize>1000)?200:pageSize;
     int start=(page-1)*pageSize, end=page*pageSize;
     StringBuilder sb=new StringBuilder();
     sb.append("SELECT * FROM (SELECT a.*,ROWNUM rn FROM (SELECT * FROM \"")
       .append(schema.toUpperCase()).append("\".\"").append(table.toUpperCase()).append("\"");
     if(filterCol!=null&&!filterCol.isEmpty()&&filterVal!=null&&!filterVal.isEmpty())
         sb.append(" WHERE UPPER(\"").append(filterCol).append("\") LIKE UPPER('%").append(filterVal.replace("'","''")).append("%')");
     if(orderCol!=null&&!orderCol.isEmpty())
         sb.append(" ORDER BY \"").append(orderCol).append("\"").append("DESC".equalsIgnoreCase(orderDir)?" DESC":" ASC");
     sb.append(") a WHERE ROWNUM<=").append(end).append(") WHERE rn>").append(start);
     return runQuery(conn,sb.toString(),pageSize);
 }

 private ObjectNode oraGetRowCount(Connection conn,String schema,String table) throws Exception {
     ObjectNode r=obj(); Statement st=null; ResultSet rs=null;
     try {
         st=conn.createStatement();
         rs=st.executeQuery("SELECT COUNT(*) FROM \""+schema.toUpperCase()+"\".\""+table.toUpperCase()+"\"");
         r.put("success",true); r.put("rowCount",rs.next()?rs.getLong(1):0L);
     } finally { close(rs,st); }
     return r;
 }

 private ObjectNode oraGetDDL(Connection conn,String schema,String objType,String objName) throws Exception {
     ObjectNode r=obj(); Statement st=null; ResultSet rs=null;
     try {
         st=conn.createStatement();
         rs=st.executeQuery("SELECT DBMS_METADATA.GET_DDL('"+objType.toUpperCase()+"','"+objName.toUpperCase()+"','"+schema.toUpperCase()+"') FROM DUAL");
         if(rs.next()){
             Object v=rs.getObject(1);
             String ddl=(v instanceof Clob)?((Clob)v).getSubString(1,(int)Math.min(((Clob)v).length(),200000)):v.toString();
             r.put("ddl",ddl); r.put("success",true);
         } else { r.put("success",false); r.put("error","No DDL returned"); }
     } finally { close(rs,st); }
     return r;
 }

 private ObjectNode oraGetObjectSource(Connection conn,String schema,String objType,String objName) throws Exception {
     ObjectNode r=runQueryPS(conn,"SELECT line,text FROM all_source WHERE owner=? AND name=? AND type=? ORDER BY line",50000,schema.toUpperCase(),objName.toUpperCase(),objType.toUpperCase());
     if(r.path("success").asBoolean(false)){
         StringBuilder sb=new StringBuilder();
         JsonNode rows=r.get("rows");
         if(rows!=null){for(JsonNode row:rows){JsonNode t=row.get("TEXT");if(t!=null&&!t.isNull())sb.append(t.asText());}}
         r.put("source",sb.toString());
     }
     return r;
 }

 private ObjectNode oraGetConstraints(Connection conn,String schema,String table) throws Exception {
     return runQueryPS(conn,
         "SELECT c.constraint_name,c.constraint_type,c.status,c.search_condition,c.r_owner,c.r_constraint_name,c.delete_rule,"+
         "LISTAGG(cc.column_name,',') WITHIN GROUP (ORDER BY cc.position) AS columns "+
         "FROM all_constraints c JOIN all_cons_columns cc ON cc.owner=c.owner AND cc.constraint_name=c.constraint_name "+
         "WHERE c.owner=? AND c.table_name=? GROUP BY c.constraint_name,c.constraint_type,c.status,c.search_condition,c.r_owner,c.r_constraint_name,c.delete_rule ORDER BY c.constraint_type",
         500,schema.toUpperCase(),table.toUpperCase());
 }
 private ObjectNode oraGetIndexes(Connection conn,String schema,String table) throws Exception {
     return runQueryPS(conn,
         "SELECT i.index_name,i.index_type,i.uniqueness,i.status,i.partitioned,"+
         "LISTAGG(ic.column_name,',') WITHIN GROUP (ORDER BY ic.column_position) AS columns "+
         "FROM all_indexes i JOIN all_ind_columns ic ON ic.index_owner=i.owner AND ic.index_name=i.index_name "+
         "WHERE i.owner=? AND i.table_name=? GROUP BY i.index_name,i.index_type,i.uniqueness,i.status,i.partitioned",
         500,schema.toUpperCase(),table.toUpperCase());
 }
 private ObjectNode oraGetTableStats(Connection conn,String schema,String table) throws Exception {
     return runQueryPS(conn,"SELECT num_rows,blocks,avg_row_len,sample_size,last_analyzed,row_movement,compression,compress_for FROM all_tables WHERE owner=? AND table_name=?",1,schema.toUpperCase(),table.toUpperCase());
 }
 private ObjectNode oraGetPartitions(Connection conn,String schema,String table) throws Exception {
     return runQueryPS(conn,"SELECT partition_name,partition_position,high_value,num_rows,tablespace_name,last_analyzed FROM all_tab_partitions WHERE table_owner=? AND table_name=? ORDER BY partition_position",500,schema.toUpperCase(),table.toUpperCase());
 }
 private ObjectNode oraGetSequences(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT sequence_name,min_value,max_value,increment_by,cycle_flag,order_flag,cache_size,last_number FROM all_sequences WHERE sequence_owner=? ORDER BY sequence_name",2000,schema.toUpperCase());
 }
 private ObjectNode oraGetTriggers(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT trigger_name,trigger_type,triggering_event,table_name,status,description FROM all_triggers WHERE owner=? ORDER BY trigger_name",2000,schema.toUpperCase());
 }
 private ObjectNode oraGetProcedures(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT object_name,object_type,status,created,last_ddl_time FROM all_objects WHERE owner=? AND object_type IN ('PROCEDURE','FUNCTION','PACKAGE','PACKAGE BODY') ORDER BY object_type,object_name",2000,schema.toUpperCase());
 }
 private ObjectNode oraGetSynonyms(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT synonym_name,table_owner,table_name,db_link FROM all_synonyms WHERE owner=? ORDER BY synonym_name",2000,schema.toUpperCase());
 }
 private ObjectNode oraGetDbLinks(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT owner,db_link,username,host,created FROM all_db_links WHERE owner=? ORDER BY db_link",500,schema.toUpperCase());
 }
 private ObjectNode oraMaterializedViews(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT mview_name,refresh_method,refresh_mode,last_refresh_date,staleness,query FROM all_mviews WHERE owner=? ORDER BY mview_name",2000,schema.toUpperCase());
 }
 private ObjectNode oraGetTypes(Connection conn,String schema) throws Exception {
     return runQueryPS(conn,"SELECT type_name,typecode,attributes,methods FROM all_types WHERE owner=? ORDER BY type_name",2000,schema.toUpperCase());
 }
 private ObjectNode oraGetDatabaseObjects(Connection conn,String schema,String objType) throws Exception {
     return runQueryPS(conn,"SELECT object_name,object_type,status,created,last_ddl_time FROM all_objects WHERE owner=? AND object_type=? ORDER BY object_name",5000,schema.toUpperCase(),objType.toUpperCase());
 }
 private ObjectNode oraExecuteQuery(Connection conn,String sql,int maxRows) throws Exception {
     if(maxRows<=0) maxRows=500; return runQuery(conn,sql,maxRows);
 }
 private ObjectNode oraExecuteNonQuery(Connection conn,String sql) throws Exception {
     ObjectNode r=obj(); Statement st=null;
     try {
         conn.setAutoCommit(false); st=conn.createStatement();
         int affected=st.executeUpdate(sql); conn.commit();
         r.put("success",true); r.put("rowsAffected",affected);
         r.put("message","Executed successfully. Rows affected: "+affected);
     } catch(Exception e) {
         try{conn.rollback();}catch(Exception ignore){}
         r.put("success",false); r.put("error",e.getMessage());
     } finally { try{conn.setAutoCommit(true);}catch(Exception ignore){} close(st); }
     return r;
 }
 private ObjectNode oraExplainPlan(Connection conn,String sql) throws Exception {
     ObjectNode r=obj(); Statement st=null; ResultSet rs=null;
     try {
         st=conn.createStatement(); st.execute("EXPLAIN PLAN FOR "+sql);
         rs=st.executeQuery("SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE',NULL,'ALL'))");
         ArrayNode lines=arr(); while(rs.next()) lines.add(rs.getString(1));
         r.set("plan",lines); r.put("success",true);
     } finally { close(rs,st); }
     return r;
 }
 private ObjectNode oraGetDependencies(Connection conn,String schema,String name,String type) throws Exception {
     return runQueryPS(conn,"SELECT name,type,referenced_owner,referenced_name,referenced_type,dependency_type FROM all_dependencies WHERE owner=? AND name=? AND type=? ORDER BY referenced_type,referenced_name",1000,schema.toUpperCase(),name.toUpperCase(),type.toUpperCase());
 }
 private ObjectNode oraSearch(Connection conn,String term) throws Exception {
     return runQueryPS(conn,"SELECT owner,object_type,object_name,status FROM all_objects WHERE UPPER(object_name) LIKE UPPER(?) ORDER BY owner,object_type,object_name",500,"%"+term+"%");
 }
 private ObjectNode oraGetSessionInfo(Connection conn) throws Exception {
     return runQuery(conn,"SELECT sid,serial#,username,status,machine,program,logon_time,sql_id,event,wait_class FROM v$session WHERE type='USER' ORDER BY logon_time DESC",200);
 }
 private ObjectNode oraGetTablespaces(Connection conn) throws Exception {
     return runQuery(conn,"SELECT tablespace_name,status,contents,logging,bigfile FROM dba_tablespaces ORDER BY tablespace_name",200);
 }
 private ObjectNode oraGetLobData(Connection conn,String schema,String table,String col,String where) throws Exception {
     ObjectNode r=obj(); Statement st=null; ResultSet rs=null;
     try {
         st=conn.createStatement();
         rs=st.executeQuery("SELECT \""+col+"\" FROM \""+schema.toUpperCase()+"\".\""+table.toUpperCase()+"\" WHERE "+where);
         if(rs.next()){
             Object v=rs.getObject(1); r.put("success",true);
             if(v instanceof Clob){Clob c=(Clob)v;r.put("type","CLOB");r.put("data",c.getSubString(1,(int)Math.min(c.length(),500000)));}
             else if(v instanceof Blob){Blob b=(Blob)v;r.put("type","BLOB");r.put("lengthBytes",b.length());r.put("data",Base64.getEncoder().encodeToString(b.getBytes(1,(int)Math.min(b.length(),1048576))));}
             else{r.put("type","VARCHAR");r.put("data",v==null?"":v.toString());}
         } else{r.put("success",false);r.put("error","No row found");}
     } finally { close(rs,st); }
     return r;
 }
 private ObjectNode oraGetPerformance(Connection conn) throws Exception {
     ObjectNode r=obj(); Statement st=null; ResultSet rs=null;
     try {
         st=conn.createStatement();
         rs=st.executeQuery("SELECT sql_id,sql_text,executions,elapsed_time/1e6 elapsed_sec,cpu_time/1e6 cpu_sec,buffer_gets,disk_reads FROM v$sql ORDER BY elapsed_time DESC FETCH FIRST 20 ROWS ONLY");
         ArrayNode topSql=arr(); ResultSetMetaData md=rs.getMetaData();
         while(rs.next()){ObjectNode o=obj();for(int i=1;i<=md.getColumnCount();i++)o.put(md.getColumnName(i),rs.getString(i));topSql.add(o);}
         r.set("topSql",topSql); close(rs);
         rs=st.executeQuery("SELECT COUNT(*) FROM v$session WHERE status='ACTIVE' AND type='USER'");
         r.put("activeSessions",rs.next()?rs.getInt(1):0); r.put("success",true);
     } catch(Exception e){r.put("success",false);r.put("error",e.getMessage());}
     finally{close(rs,st);}
     return r;
 }
 private ObjectNode oraGetStorageInfo(Connection conn) throws Exception {
     return runQuery(conn,
         "SELECT df.tablespace_name,df.total_mb,fs.free_mb,ROUND((df.total_mb-NVL(fs.free_mb,0))/df.total_mb*100,1) pct_used "+
         "FROM (SELECT tablespace_name,ROUND(SUM(bytes)/1048576) total_mb FROM dba_data_files GROUP BY tablespace_name) df "+
         "LEFT JOIN (SELECT tablespace_name,ROUND(SUM(bytes)/1048576) free_mb FROM dba_free_space GROUP BY tablespace_name) fs "+
         "ON df.tablespace_name=fs.tablespace_name ORDER BY df.tablespace_name",200);
 }

 // ?? LDAP actions ??????????????????????????????????????????????????????

 private DirContext getLdapContext(String ldapUrl,String bindDn,String bindPass) throws Exception {
     Hashtable<String,String> env=new Hashtable<String,String>();
     env.put(javax.naming.Context.INITIAL_CONTEXT_FACTORY,"com.sun.jndi.ldap.LdapCtxFactory");
     env.put(javax.naming.Context.PROVIDER_URL,ldapUrl);
     env.put(javax.naming.Context.SECURITY_AUTHENTICATION,"simple");
     env.put(javax.naming.Context.SECURITY_PRINCIPAL,bindDn);
     env.put(javax.naming.Context.SECURITY_CREDENTIALS,bindPass);
     env.put("com.sun.jndi.ldap.connect.timeout","5000");
     env.put("com.sun.jndi.ldap.read.timeout","15000");
     env.put(javax.naming.Context.REFERRAL,"ignore");
     return new InitialDirContext(env);
 }

 private ObjectNode ldapEntryToJson(SearchResult sr) throws Exception {
     ObjectNode o=obj(); o.put("dn",sr.getNameInNamespace());
     Attributes attrs=sr.getAttributes();
     NamingEnumeration<? extends Attribute> ae=attrs.getAll();
     while(ae.hasMore()){
         Attribute a=ae.next();
         if(a.size()==1){Object v=a.get();o.put(a.getID(),v instanceof byte[]?Base64.getEncoder().encodeToString((byte[])v):v.toString());}
         else{ArrayNode an=arr();NamingEnumeration<?> ne=a.getAll();while(ne.hasMore()){Object v=ne.next();an.add(v instanceof byte[]?Base64.getEncoder().encodeToString((byte[])v):v.toString());}o.set(a.getID(),an);}
     }
     return o;
 }

 private ObjectNode ldapSearch(String ldapUrl,String bindDn,String bindPass,String baseDn,String filter,String[] retAttrs,int scope,int maxResults) throws Exception {
     ObjectNode r=obj(); DirContext ctx=null;
     try {
         ctx=getLdapContext(ldapUrl,bindDn,bindPass);
         SearchControls sc=new SearchControls();
         sc.setSearchScope(scope); sc.setCountLimit(maxResults<=0?200:maxResults); sc.setTimeLimit(20000);
         if(retAttrs!=null&&retAttrs.length>0) sc.setReturningAttributes(retAttrs);
         NamingEnumeration<SearchResult> results=ctx.search(baseDn,filter,sc);
         ArrayNode entries=arr();
         while(results.hasMore()){
             try{entries.add(ldapEntryToJson(results.next()));}
             catch(javax.naming.PartialResultException pre){break;}
             catch(javax.naming.SizeLimitExceededException sle){break;}
         }
         r.set("entries",entries); r.put("count",entries.size()); r.put("success",true);
     } finally { if(ctx!=null)try{ctx.close();}catch(Exception ignore){} }
     return r;
 }

 private ObjectNode ldapCheckConnection(String ldapUrl,String bindDn,String bindPass) throws Exception {
     ObjectNode r=obj(); DirContext ctx=null;
     try {
         ctx=getLdapContext(ldapUrl,bindDn,bindPass);
         Attributes attrs=ctx.getAttributes("",new String[]{"namingContexts","defaultNamingContext","supportedLDAPVersion"});
         ObjectNode info=obj();
         NamingEnumeration<? extends Attribute> ae=attrs.getAll();
         while(ae.hasMore()){
             Attribute a=ae.next(); ArrayNode an=arr();
             NamingEnumeration<?> ve=a.getAll(); while(ve.hasMore()) an.add(ve.next().toString());
             if(an.size()==1) info.put(a.getID(),an.get(0).asText()); else info.set(a.getID(),an);
         }
         r.set("serverInfo",info); r.put("success",true); r.put("message","LDAP connected to "+ldapUrl);
     } finally { if(ctx!=null)try{ctx.close();}catch(Exception ignore){} }
     return r;
 }

 private ObjectNode ldapGetTree(String ldapUrl,String bindDn,String bindPass,String baseDn,int maxDepth) throws Exception {
     DirContext ctx=null;
     try {
         ctx=getLdapContext(ldapUrl,bindDn,bindPass);
         ObjectNode root=buildLdapTree(ctx,baseDn,0,maxDepth<=0?2:maxDepth);
         ObjectNode r=obj(); r.set("tree",root); r.put("success",true); return r;
     } finally { if(ctx!=null)try{ctx.close();}catch(Exception ignore){} }
 }

 private ObjectNode buildLdapTree(DirContext ctx,String dn,int depth,int maxDepth) throws Exception {
     ObjectNode node=obj(); node.put("dn",dn);
     try {
         Attributes attrs=ctx.getAttributes(dn,new String[]{"cn","ou","dc","objectClass"});
         Attribute cnA=attrs.get("cn"); if(cnA!=null) node.put("cn",cnA.get().toString());
         Attribute ouA=attrs.get("ou"); if(ouA!=null) node.put("ou",ouA.get().toString());
         Attribute ocA=attrs.get("objectClass");
         if(ocA!=null){ArrayNode oc=arr();NamingEnumeration<?> ne=ocA.getAll();while(ne.hasMore())oc.add(ne.next().toString());node.set("objectClass",oc);}
     } catch(Exception ignore){}
     if(depth<maxDepth){
         SearchControls sc=new SearchControls(); sc.setSearchScope(SearchControls.ONELEVEL_SCOPE);
         sc.setCountLimit(100); sc.setReturningAttributes(new String[]{"cn","ou","dc","objectClass"});
         ArrayNode children=arr();
         try {
             NamingEnumeration<SearchResult> res=ctx.search(dn,"(objectClass=*)",sc);
             while(res.hasMore()){try{SearchResult sr=res.next();children.add(buildLdapTree(ctx,sr.getNameInNamespace(),depth+1,maxDepth));}catch(Exception ignore){}}
         } catch(Exception ignore){}
         node.set("children",children);
     }
     return node;
 }

 private String p(HttpServletRequest req,String name){ String v=req.getParameter(name); return v==null?"":v.trim(); }
 private int pi(HttpServletRequest req,String name,int def){ try{return Integer.parseInt(p(req,name));}catch(Exception e){return def;} }

    // ?? Direct JDBC fallback credentials (from master-datasources.xml) ???
    private static final String ORA_URL_CARBON   = "jdbc:oracle:thin:@idnt01cic.paaet.edu.kw:1521:iddb";
    private static final String ORA_URL_SHARED   = "jdbc:oracle:thin:@idnt01cic.paaet.edu.kw:1521:iddb";
    private static final String ORA_URL_IDENTITY = "jdbc:oracle:thin:@idnt01cic.paaet.edu.kw:1521:iddb";
    private static final String ORA_USER_CARBON   = "ethosdb";
    private static final String ORA_USER_SHARED   = "ethosreg";
    private static final String ORA_USER_IDENTITY = "ethosmet";
    // Passwords – fill in (or pass as request params when using 'direct' mode)
    private static final String ORA_PASS_CARBON   = "u_pick_it";
    private static final String ORA_PASS_SHARED   = "u_pick_it";
    private static final String ORA_PASS_IDENTITY = "u_pick_it";
    private static final String ORA_DRIVER = "oracle.jdbc.driver.OracleDriver";

    // ?? LDAP (from user-mgt.xml) ??????????????????????????????????????????
    private static final String LDAP_URL  = "ldap://PAAET.edu:389";
    private static final String LDAP_BIND = "CN=ethos SSO,OU=Service Accounts,OU=Service Admins,DC=paaet,DC=edu";
    private static final String LDAP_PASS = "P@@et@321";
    private static final String LDAP_BASE = "DC=paaet,DC=edu";

    static {
        try { Class.forName(ORA_DRIVER); } catch (Exception e) { /* driver already loaded in WSO2 */ }
    }

    // ?????????????????????????????????????????????????????????????????????
    //  Connection helpers
    // ?????????????????????????????????????????????????????????????????????

    /** Resolve a connection – try JNDI first, fall back to direct JDBC */
    private Connection getConnection(String dsKey,
                                     String customUrl, String customUser, String customPass)
            throws SQLException {
        // JNDI datasource names registered by WSO2 Carbon
        String jndiName = null;
        String fallbackUrl = null, fallbackUser = null, fallbackPass = null;
        switch (dsKey == null ? "carbon" : dsKey.toLowerCase()) {
            case "shared":
                jndiName = "jdbc/SHARED_DB";
                fallbackUrl = ORA_URL_SHARED; fallbackUser = ORA_USER_SHARED; fallbackPass = ORA_PASS_SHARED;
                break;
            case "identity":
                jndiName = "jdbc/WSO2IdentityDB";
                fallbackUrl = ORA_URL_IDENTITY; fallbackUser = ORA_USER_IDENTITY; fallbackPass = ORA_PASS_IDENTITY;
                break;
            case "direct":
                // caller passes explicit creds
                if (customUrl != null && !customUrl.isEmpty()) {
                    return DriverManager.getConnection(customUrl, customUser, customPass);
                }
                // fall through to carbon
            default: // "carbon"
                jndiName = "jdbc/WSO2CarbonDB";
                fallbackUrl = ORA_URL_CARBON; fallbackUser = ORA_USER_CARBON; fallbackPass = ORA_PASS_CARBON;
                break;
        }
        // Try JNDI
        try {
            InitialContext ctx = new InitialContext();
            DataSource ds = null;
            // Try both common JNDI lookup paths used by WSO2/Tomcat
            try { ds = (DataSource) ctx.lookup(jndiName); }
            catch (NamingException e1) {
                try { ds = (DataSource) ctx.lookup("java:comp/env/" + jndiName); }
                catch (NamingException e2) { /* fall through to direct */ }
            }
            if (ds != null) return ds.getConnection();
        } catch (Exception ignore) { }
        // Direct JDBC fallback
        return DriverManager.getConnection(fallbackUrl, fallbackUser, fallbackPass);
    }

    private void close(AutoCloseable... cs) {
        for (AutoCloseable c : cs) try { if (c != null) c.close(); } catch (Exception ignore) { }
    }

    // ?????????????????????????????????????????????????????????????????????
    //  Generic query runner – returns JSONObject {success, columns[], rows[][]}
    // ?????????????????????????????????????????????????????????????????????
    private JSONObject runQuery(Connection conn, String sql, int maxRows) throws Exception {
        JSONObject r = new JSONObject();
        PreparedStatement ps = null; ResultSet rs = null;
        try {
            ps = conn.prepareStatement(sql);
            ps.setFetchSize(200);
            if (maxRows > 0) ps.setMaxRows(maxRows);
            rs = ps.executeQuery();
            ResultSetMetaData md = rs.getMetaData();
            int cc = md.getColumnCount();
            JSONArray cols = new JSONArray();
            for (int i = 1; i <= cc; i++) cols.put(md.getColumnName(i));
            r.put("columns", cols);
            JSONArray rows = new JSONArray();
            SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
            int count = 0;
            while (rs.next() && (maxRows <= 0 || count++ < maxRows)) {
                JSONArray row = new JSONArray();
                for (int i = 1; i <= cc; i++) {
                    Object v = rs.getObject(i);
                    if (v == null) row.put(JSONObject.NULL);
                    else if (v instanceof Clob) { Clob c = (Clob)v; row.put(c.getSubString(1,(int)Math.min(c.length(),65535))); }
                    else if (v instanceof Blob) row.put("[BLOB " + ((Blob)v).length() + " bytes]");
                    else if (v instanceof java.sql.Timestamp || v instanceof java.sql.Date) row.put(sdf.format(v));
                    else row.put(v.toString());
                }
                rows.put(row);
            }
            r.put("rows", rows);
            r.put("rowCount", rows.length());
            r.put("success", true);
        } finally { close(rs, ps); }
        return r;
    }

    /** Run a parameterised query using positional ? and Object[] args */
    private JSONObject runQueryPS(Connection conn, String sql, int maxRows, Object... args) throws Exception {
        JSONObject r = new JSONObject();
        PreparedStatement ps = null; ResultSet rs = null;
        try {
            ps = conn.prepareStatement(sql);
            ps.setFetchSize(200);
            if (maxRows > 0) ps.setMaxRows(maxRows);
            for (int i = 0; i < args.length; i++) ps.setObject(i + 1, args[i]);
            rs = ps.executeQuery();
            ResultSetMetaData md = rs.getMetaData();
            int cc = md.getColumnCount();
            JSONArray cols = new JSONArray();
            for (int i = 1; i <= cc; i++) {
                JSONObject col = new JSONObject();
                col.put("name", md.getColumnName(i));
                col.put("type", md.getColumnTypeName(i));
                cols.put(col);
            }
            r.put("columns", cols);
            JSONArray rows = new JSONArray();
            SimpleDateFormat sdf = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss");
            int count = 0;
            while (rs.next() && (maxRows <= 0 || count++ < maxRows)) {
                JSONObject row = new JSONObject();
                for (int i = 1; i <= cc; i++) {
                    String cn = md.getColumnName(i);
                    Object v = rs.getObject(i);
                    if (v == null) row.put(cn, JSONObject.NULL);
                    else if (v instanceof Clob) { Clob c = (Clob)v; row.put(cn, c.getSubString(1,(int)Math.min(c.length(),65535))); }
                    else if (v instanceof Blob) row.put(cn, "[BLOB " + ((Blob)v).length() + " bytes]");
                    else if (v instanceof java.sql.Timestamp || v instanceof java.sql.Date) row.put(cn, sdf.format(v));
                    else row.put(cn, v.toString());
                }
                rows.put(row);
            }
            r.put("rows", rows);
            r.put("rowCount", rows.length());
            r.put("success", true);
        } finally { close(rs, ps); }
        return r;
    }

    // ?????????????????????????????????????????????????????????????????????
    //  Oracle actions
    // ?????????????????????????????????????????????????????????????????????

    private JSONObject oraCheckConnection(Connection conn) throws Exception {
        JSONObject r = new JSONObject();
        Statement st = null; ResultSet rs = null;
        try {
            st = conn.createStatement();
            rs = st.executeQuery("SELECT SYS_CONTEXT('USERENV','DB_NAME') DB, SYS_CONTEXT('USERENV','SESSION_USER') USR, SYS_CONTEXT('USERENV','SERVER_HOST') HOST FROM DUAL");
            if (rs.next()) {
                r.put("db", rs.getString(1));
                r.put("user", rs.getString(2));
                r.put("host", rs.getString(3));
            }
            r.put("success", true);
            r.put("message", "Connected");
        } finally { close(rs, st); }
        return r;
    }

    private JSONObject oraGetSchemas(Connection conn) throws Exception {
        return runQueryPS(conn,
            "SELECT DISTINCT owner AS SCHEMA_NAME, " +
            "(SELECT COUNT(*) FROM all_objects o2 WHERE o2.owner=ao.owner AND o2.object_type='TABLE') TABLE_COUNT " +
            "FROM all_objects ao ORDER BY owner", 500);
    }

    private JSONObject oraGetTables(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT t.table_name, t.num_rows, t.last_analyzed, t.tablespace_name, " +
            "c.comments " +
            "FROM all_tables t LEFT JOIN all_tab_comments c ON c.owner=t.owner AND c.table_name=t.table_name " +
            "WHERE t.owner=? ORDER BY t.table_name", 2000, schema.toUpperCase());
    }

    private JSONObject oraGetViews(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT view_name, text_length FROM all_views WHERE owner=? ORDER BY view_name", 2000, schema.toUpperCase());
    }

    private JSONObject oraGetTableColumns(Connection conn, String schema, String table) throws Exception {
        return runQueryPS(conn,
            "SELECT c.column_name, c.data_type, c.data_length, c.data_precision, c.data_scale, " +
            "c.nullable, c.data_default, c.column_id, cc.comments " +
            "FROM all_tab_columns c " +
            "LEFT JOIN all_col_comments cc ON cc.owner=c.owner AND cc.table_name=c.table_name AND cc.column_name=c.column_name " +
            "WHERE c.owner=? AND c.table_name=? ORDER BY c.column_id",
            500, schema.toUpperCase(), table.toUpperCase());
    }

    private JSONObject oraGetTableData(Connection conn, String schema, String table,
                                        int page, int pageSize,
                                        String filterCol, String filterVal,
                                        String orderCol, String orderDir) throws Exception {
        page = Math.max(1, page);
        pageSize = (pageSize <= 0 || pageSize > 1000) ? 200 : pageSize;
        int start = (page - 1) * pageSize;
        int end   = page * pageSize;

        StringBuilder sb = new StringBuilder();
        sb.append("SELECT * FROM (SELECT a.*, ROWNUM rn FROM (SELECT * FROM \"")
          .append(schema.toUpperCase()).append("\".\"").append(table.toUpperCase()).append("\"");
        if (filterCol != null && !filterCol.isEmpty() && filterVal != null && !filterVal.isEmpty())
            sb.append(" WHERE UPPER(\"").append(filterCol).append("\") LIKE UPPER('%").append(filterVal.replace("'","''")).append("%')");
        if (orderCol != null && !orderCol.isEmpty())
            sb.append(" ORDER BY \"").append(orderCol).append("\"").append("DESC".equalsIgnoreCase(orderDir) ? " DESC" : " ASC");
        sb.append(") a WHERE ROWNUM<=").append(end).append(") WHERE rn>").append(start);

        return runQuery(conn, sb.toString(), pageSize);
    }

    private JSONObject oraGetRowCount(Connection conn, String schema, String table) throws Exception {
        JSONObject r = new JSONObject();
        Statement st = null; ResultSet rs = null;
        try {
            st = conn.createStatement();
            rs = st.executeQuery("SELECT COUNT(*) FROM \"" + schema.toUpperCase() + "\".\"" + table.toUpperCase() + "\"");
            r.put("success", true);
            r.put("rowCount", rs.next() ? rs.getLong(1) : 0);
        } finally { close(rs, st); }
        return r;
    }

    private JSONObject oraGetDDL(Connection conn, String schema, String objType, String objName) throws Exception {
        JSONObject r = new JSONObject();
        Statement st = null; ResultSet rs = null;
        try {
            st = conn.createStatement();
            // Use DBMS_METADATA
            rs = st.executeQuery(
                "SELECT DBMS_METADATA.GET_DDL('" + objType.toUpperCase() + "','" +
                objName.toUpperCase() + "','" + schema.toUpperCase() + "') FROM DUAL");
            if (rs.next()) {
                Object v = rs.getObject(1);
                String ddl = (v instanceof Clob) ?
                    ((Clob)v).getSubString(1,(int)Math.min(((Clob)v).length(),200000)) : v.toString();
                r.put("ddl", ddl);
                r.put("success", true);
            } else {
                r.put("success", false); r.put("error", "No DDL returned");
            }
        } finally { close(rs, st); }
        return r;
    }

    private JSONObject oraGetObjectSource(Connection conn, String schema, String objType, String objName) throws Exception {
        JSONObject r = runQueryPS(conn,
            "SELECT line, text FROM all_source WHERE owner=? AND name=? AND type=? ORDER BY line",
            50000, schema.toUpperCase(), objName.toUpperCase(), objType.toUpperCase());
        // Also concatenate into single 'source' string for convenience
        if (r.optBoolean("success")) {
            StringBuilder sb = new StringBuilder();
            JSONArray rows = r.getJSONArray("rows");
            for (int i = 0; i < rows.length(); i++) {
                JSONObject row = rows.getJSONObject(i);
                sb.append(row.optString("TEXT", ""));
            }
            r.put("source", sb.toString());
        }
        return r;
    }

    private JSONObject oraGetConstraints(Connection conn, String schema, String table) throws Exception {
        return runQueryPS(conn,
            "SELECT c.constraint_name, c.constraint_type, c.status, c.search_condition, " +
            "c.r_owner, c.r_constraint_name, c.delete_rule, " +
            "LISTAGG(cc.column_name,',') WITHIN GROUP (ORDER BY cc.position) AS columns " +
            "FROM all_constraints c " +
            "JOIN all_cons_columns cc ON cc.owner=c.owner AND cc.constraint_name=c.constraint_name " +
            "WHERE c.owner=? AND c.table_name=? GROUP BY c.constraint_name,c.constraint_type," +
            "c.status,c.search_condition,c.r_owner,c.r_constraint_name,c.delete_rule ORDER BY c.constraint_type",
            500, schema.toUpperCase(), table.toUpperCase());
    }

    private JSONObject oraGetIndexes(Connection conn, String schema, String table) throws Exception {
        return runQueryPS(conn,
            "SELECT i.index_name, i.index_type, i.uniqueness, i.status, i.partitioned, " +
            "LISTAGG(ic.column_name,',') WITHIN GROUP (ORDER BY ic.column_position) AS columns " +
            "FROM all_indexes i " +
            "JOIN all_ind_columns ic ON ic.index_owner=i.owner AND ic.index_name=i.index_name " +
            "WHERE i.owner=? AND i.table_name=? GROUP BY i.index_name,i.index_type,i.uniqueness,i.status,i.partitioned",
            500, schema.toUpperCase(), table.toUpperCase());
    }

    private JSONObject oraGetTableStats(Connection conn, String schema, String table) throws Exception {
        return runQueryPS(conn,
            "SELECT num_rows, blocks, avg_row_len, sample_size, last_analyzed, " +
            "row_movement, compression, compress_for " +
            "FROM all_tables WHERE owner=? AND table_name=?",
            1, schema.toUpperCase(), table.toUpperCase());
    }

    private JSONObject oraGetPartitions(Connection conn, String schema, String table) throws Exception {
        return runQueryPS(conn,
            "SELECT partition_name, partition_position, high_value, num_rows, tablespace_name, last_analyzed " +
            "FROM all_tab_partitions WHERE table_owner=? AND table_name=? ORDER BY partition_position",
            500, schema.toUpperCase(), table.toUpperCase());
    }

    private JSONObject oraGetSequences(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT sequence_name, min_value, max_value, increment_by, cycle_flag, order_flag, cache_size, last_number " +
            "FROM all_sequences WHERE sequence_owner=? ORDER BY sequence_name",
            2000, schema.toUpperCase());
    }

    private JSONObject oraGetTriggers(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT trigger_name, trigger_type, triggering_event, table_name, status, description " +
            "FROM all_triggers WHERE owner=? ORDER BY trigger_name",
            2000, schema.toUpperCase());
    }

    private JSONObject oraGetProcedures(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT object_name, object_type, status, created, last_ddl_time " +
            "FROM all_objects WHERE owner=? AND object_type IN ('PROCEDURE','FUNCTION','PACKAGE','PACKAGE BODY') " +
            "ORDER BY object_type, object_name",
            2000, schema.toUpperCase());
    }

    private JSONObject oraGetSynonyms(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT synonym_name, table_owner, table_name, db_link FROM all_synonyms WHERE owner=? ORDER BY synonym_name",
            2000, schema.toUpperCase());
    }

    private JSONObject oraGetDbLinks(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT owner, db_link, username, host, created FROM all_db_links WHERE owner=? ORDER BY db_link",
            500, schema.toUpperCase());
    }

    private JSONObject oraMaterializedViews(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT mview_name, refresh_method, refresh_mode, last_refresh_date, staleness, query " +
            "FROM all_mviews WHERE owner=? ORDER BY mview_name",
            2000, schema.toUpperCase());
    }

    private JSONObject oraGetTypes(Connection conn, String schema) throws Exception {
        return runQueryPS(conn,
            "SELECT type_name, typecode, attributes, methods FROM all_types WHERE owner=? ORDER BY type_name",
            2000, schema.toUpperCase());
    }

    private JSONObject oraGetDatabaseObjects(Connection conn, String schema, String objType) throws Exception {
        return runQueryPS(conn,
            "SELECT object_name, object_type, status, created, last_ddl_time " +
            "FROM all_objects WHERE owner=? AND object_type=? ORDER BY object_name",
            5000, schema.toUpperCase(), objType.toUpperCase());
    }

    private JSONObject oraExecuteQuery(Connection conn, String sql, int maxRows) throws Exception {
        if (maxRows <= 0) maxRows = 500;
        return runQuery(conn, sql, maxRows);
    }

    private JSONObject oraExecuteNonQuery(Connection conn, String sql) throws Exception {
        JSONObject r = new JSONObject();
        Statement st = null;
        try {
            conn.setAutoCommit(false);
            st = conn.createStatement();
            int affected = st.executeUpdate(sql);
            conn.commit();
            r.put("success", true);
            r.put("rowsAffected", affected);
            r.put("message", "Executed successfully. Rows affected: " + affected);
        } catch (Exception e) {
            try { conn.rollback(); } catch (Exception ignore) { }
            r.put("success", false);
            r.put("error", e.getMessage());
        } finally {
            try { conn.setAutoCommit(true); } catch (Exception ignore) { }
            close(st);
        }
        return r;
    }

    private JSONObject oraExplainPlan(Connection conn, String sql) throws Exception {
        JSONObject r = new JSONObject();
        Statement st = null; ResultSet rs = null;
        try {
            st = conn.createStatement();
            st.execute("EXPLAIN PLAN FOR " + sql);
            rs = st.executeQuery("SELECT * FROM TABLE(DBMS_XPLAN.DISPLAY('PLAN_TABLE',NULL,'ALL'))");
            JSONArray lines = new JSONArray();
            while (rs.next()) lines.put(rs.getString(1));
            r.put("plan", lines);
            r.put("success", true);
        } finally { close(rs, st); }
        return r;
    }

    private JSONObject oraGetDependencies(Connection conn, String schema, String name, String type) throws Exception {
        return runQueryPS(conn,
            "SELECT name, type, referenced_owner, referenced_name, referenced_type, dependency_type " +
            "FROM all_dependencies WHERE owner=? AND name=? AND type=? ORDER BY referenced_type, referenced_name",
            1000, schema.toUpperCase(), name.toUpperCase(), type.toUpperCase());
    }

    private JSONObject oraSearch(Connection conn, String term) throws Exception {
        return runQueryPS(conn,
            "SELECT owner, object_type, object_name, status FROM all_objects " +
            "WHERE UPPER(object_name) LIKE UPPER(?) ORDER BY owner, object_type, object_name",
            500, "%" + term + "%");
    }

    private JSONObject oraGetSessionInfo(Connection conn) throws Exception {
        return runQuery(conn,
            "SELECT sid, serial#, username, status, machine, program, logon_time, " +
            "sql_id, event, wait_class FROM v$session WHERE type='USER' ORDER BY logon_time DESC",
            200);
    }

    private JSONObject oraGetTablespaces(Connection conn) throws Exception {
        return runQuery(conn,
            "SELECT tablespace_name, status, contents, logging, bigfile FROM dba_tablespaces ORDER BY tablespace_name",
            200);
    }

    private JSONObject oraGetLobData(Connection conn, String schema, String table, String col, String where) throws Exception {
        JSONObject r = new JSONObject();
        Statement st = null; ResultSet rs = null;
        try {
            st = conn.createStatement();
            String q = "SELECT \"" + col + "\" FROM \"" + schema.toUpperCase() + "\".\"" + table.toUpperCase() + "\" WHERE " + where;
            rs = st.executeQuery(q);
            if (rs.next()) {
                Object v = rs.getObject(1);
                r.put("success", true);
                if (v instanceof Clob) {
                    Clob c = (Clob)v;
                    r.put("type","CLOB");
                    r.put("data", c.getSubString(1,(int)Math.min(c.length(),500000)));
                } else if (v instanceof Blob) {
                    Blob b = (Blob)v;
                    r.put("type","BLOB");
                    r.put("lengthBytes", b.length());
                    r.put("data", Base64.getEncoder().encodeToString(b.getBytes(1,(int)Math.min(b.length(),1048576))));
                } else {
                    r.put("type","VARCHAR"); r.put("data", v == null ? "" : v.toString());
                }
            } else { r.put("success",false); r.put("error","No row found"); }
        } finally { close(rs, st); }
        return r;
    }

    private JSONObject oraGetPerformance(Connection conn) throws Exception {
        JSONObject r = new JSONObject();
        Statement st = null; ResultSet rs = null;
        try {
            st = conn.createStatement();
            // Top SQL by elapsed time
            rs = st.executeQuery(
                "SELECT sql_id, sql_text, executions, elapsed_time/1e6 elapsed_sec, " +
                "cpu_time/1e6 cpu_sec, buffer_gets, disk_reads " +
                "FROM v$sql ORDER BY elapsed_time DESC FETCH FIRST 20 ROWS ONLY");
            JSONArray topSql = new JSONArray();
            ResultSetMetaData md = rs.getMetaData();
            while (rs.next()) {
                JSONObject o = new JSONObject();
                for (int i=1;i<=md.getColumnCount();i++) o.put(md.getColumnName(i), rs.getString(i));
                topSql.put(o);
            }
            r.put("topSql", topSql);
            // Active sessions
            close(rs);
            rs = st.executeQuery("SELECT COUNT(*) FROM v$session WHERE status='ACTIVE' AND type='USER'");
            r.put("activeSessions", rs.next() ? rs.getInt(1) : 0);
            r.put("success", true);
        } catch (Exception e) { r.put("success",false); r.put("error",e.getMessage()); }
        finally { close(rs,st); }
        return r;
    }

    private JSONObject oraGetStorageInfo(Connection conn) throws Exception {
        return runQuery(conn,
            "SELECT df.tablespace_name, df.total_mb, fs.free_mb, " +
            "ROUND((df.total_mb-NVL(fs.free_mb,0))/df.total_mb*100,1) pct_used " +
            "FROM (SELECT tablespace_name, ROUND(SUM(bytes)/1048576) total_mb FROM dba_data_files GROUP BY tablespace_name) df " +
            "LEFT JOIN (SELECT tablespace_name, ROUND(SUM(bytes)/1048576) free_mb FROM dba_free_space GROUP BY tablespace_name) fs " +
            "ON df.tablespace_name=fs.tablespace_name ORDER BY df.tablespace_name", 200);
    }

    // ?????????????????????????????????????????????????????????????????????
    //  LDAP actions
    // ?????????????????????????????????????????????????????????????????????

    private DirContext getLdapContext(String ldapUrl, String bindDn, String bindPass) throws Exception {
        Hashtable<String,String> env = new Hashtable<String,String>();
        env.put(javax.naming.Context.INITIAL_CONTEXT_FACTORY, "com.sun.jndi.ldap.LdapCtxFactory");
        env.put(javax.naming.Context.PROVIDER_URL, ldapUrl);
        env.put(javax.naming.Context.SECURITY_AUTHENTICATION, "simple");
        env.put(javax.naming.Context.SECURITY_PRINCIPAL, bindDn);
        env.put(javax.naming.Context.SECURITY_CREDENTIALS, bindPass);
        env.put("com.sun.jndi.ldap.connect.timeout", "5000");
        env.put("com.sun.jndi.ldap.read.timeout", "15000");
        // ignore referrals (as configured in user-mgt.xml)
        env.put(javax.naming.Context.REFERRAL, "ignore");
        return new InitialDirContext(env);
    }

    private JSONObject ldapEntryToJson(SearchResult sr) throws Exception {
        JSONObject o = new JSONObject();
        o.put("dn", sr.getNameInNamespace());
        Attributes attrs = sr.getAttributes();
        NamingEnumeration<? extends Attribute> ae = attrs.getAll();
        while (ae.hasMore()) {
            Attribute a = ae.next();
            if (a.size() == 1) {
                Object v = a.get();
                o.put(a.getID(), v instanceof byte[] ? Base64.getEncoder().encodeToString((byte[])v) : v.toString());
            } else {
                JSONArray arr = new JSONArray();
                NamingEnumeration<?> ne = a.getAll();
                while (ne.hasMore()) {
                    Object v = ne.next();
                    arr.put(v instanceof byte[] ? Base64.getEncoder().encodeToString((byte[])v) : v.toString());
                }
                o.put(a.getID(), arr);
            }
        }
        return o;
    }

    private JSONObject ldapSearch(String ldapUrl, String bindDn, String bindPass,
                                   String baseDn, String filter, String[] retAttrs,
                                   int scope, int maxResults) throws Exception {
        JSONObject r = new JSONObject();
        DirContext ctx = null;
        try {
            ctx = getLdapContext(ldapUrl, bindDn, bindPass);
            SearchControls sc = new SearchControls();
            sc.setSearchScope(scope); // OBJECT=0, ONELEVEL=1, SUBTREE=2
            sc.setCountLimit(maxResults <= 0 ? 200 : maxResults);
            sc.setTimeLimit(20000);
            if (retAttrs != null && retAttrs.length > 0) sc.setReturningAttributes(retAttrs);
            NamingEnumeration<SearchResult> results = ctx.search(baseDn, filter, sc);
            JSONArray entries = new JSONArray();
            while (results.hasMore()) {
                try { entries.put(ldapEntryToJson(results.next())); }
                catch (javax.naming.PartialResultException pre) { break; }
                catch (javax.naming.SizeLimitExceededException sle) { break; }
            }
            r.put("entries", entries);
            r.put("count", entries.length());
            r.put("success", true);
        } finally {
            if (ctx != null) try { ctx.close(); } catch (Exception ignore) { }
        }
        return r;
    }

    private JSONObject ldapCheckConnection(String ldapUrl, String bindDn, String bindPass) throws Exception {
        JSONObject r = new JSONObject();
        DirContext ctx = null;
        try {
            ctx = getLdapContext(ldapUrl, bindDn, bindPass);
            Attributes attrs = ctx.getAttributes("", new String[]{"namingContexts","defaultNamingContext","supportedLDAPVersion"});
            JSONObject info = new JSONObject();
            NamingEnumeration<? extends Attribute> ae = attrs.getAll();
            while (ae.hasMore()) {
                Attribute a = ae.next();
                JSONArray arr = new JSONArray();
                NamingEnumeration<?> ve = a.getAll();
                while (ve.hasMore()) arr.put(ve.next().toString());
                info.put(a.getID(), arr.length()==1 ? arr.getString(0) : arr);
            }
            r.put("serverInfo", info);
            r.put("success", true);
            r.put("message", "LDAP connected to " + ldapUrl);
        } finally {
            if (ctx != null) try { ctx.close(); } catch (Exception ignore) { }
        }
        return r;
    }

    private JSONObject ldapGetTree(String ldapUrl, String bindDn, String bindPass,
                                    String baseDn, int maxDepth) throws Exception {
        DirContext ctx = null;
        try {
            ctx = getLdapContext(ldapUrl, bindDn, bindPass);
            JSONObject root = buildLdapTree(ctx, baseDn, 0, maxDepth <= 0 ? 2 : maxDepth);
            JSONObject r = new JSONObject();
            r.put("tree", root);
            r.put("success", true);
            return r;
        } finally {
            if (ctx != null) try { ctx.close(); } catch (Exception ignore) { }
        }
    }

    private JSONObject buildLdapTree(DirContext ctx, String dn, int depth, int maxDepth) throws Exception {
        JSONObject node = new JSONObject();
        node.put("dn", dn);
        // get CN
        try {
            Attributes attrs = ctx.getAttributes(dn, new String[]{"cn","ou","dc","objectClass"});
            Attribute cnA = attrs.get("cn"); if (cnA!=null) node.put("cn", cnA.get().toString());
            Attribute ouA = attrs.get("ou"); if (ouA!=null) node.put("ou", ouA.get().toString());
            Attribute ocA = attrs.get("objectClass");
            if (ocA!=null) { JSONArray oc=new JSONArray(); NamingEnumeration<?> ne=ocA.getAll(); while(ne.hasMore()) oc.put(ne.next().toString()); node.put("objectClass",oc); }
        } catch (Exception ignore) { }
        if (depth < maxDepth) {
            SearchControls sc = new SearchControls();
            sc.setSearchScope(SearchControls.ONELEVEL_SCOPE);
            sc.setCountLimit(100);
            sc.setReturningAttributes(new String[]{"cn","ou","dc","objectClass"});
            JSONArray children = new JSONArray();
            try {
                NamingEnumeration<SearchResult> res = ctx.search(dn, "(objectClass=*)", sc);
                while (res.hasMore()) {
                    try {
                        SearchResult sr = res.next();
                        children.put(buildLdapTree(ctx, sr.getNameInNamespace(), depth+1, maxDepth));
                    } catch (Exception ignore) { }
                }
            } catch (Exception ignore) { }
            node.put("children", children);
        }
        return node;
    }

    // ?????????????????????????????????????????????????????????????????????
    //  Safe parameter helpers
    // ?????????????????????????????????????????????????????????????????????
    private String p(HttpServletRequest req, String name) {
        String v = req.getParameter(name);
        return v == null ? "" : v.trim();
    }
    private int pi(HttpServletRequest req, String name, int def) {
        try { return Integer.parseInt(p(req, name)); } catch (Exception e) { return def; }
    }
%>
<%
    response.setContentType("application/json; charset=UTF-8");
    response.setHeader("Cache-Control","no-cache, no-store");
    response.setHeader("Access-Control-Allow-Origin","*");
    response.setHeader("Access-Control-Allow-Methods","GET,POST,OPTIONS");
    response.setHeader("Access-Control-Allow-Headers","Content-Type,Authorization");

    if ("OPTIONS".equals(request.getMethod())) { response.setStatus(200); return; }

    ObjectNode result = MAPPER.createObjectNode();

    // ?? Token check ???????????????????????????????????????????????????????
    String token = p(request, "token");
    String authHeader = request.getHeader("Authorization");
    if (authHeader != null && authHeader.startsWith("Bearer ")) token = authHeader.substring(7).trim();
    if (!ACCESS_TOKEN.equals(token)) {
        result.put("success", false);
        result.put("error", "Unauthorized: invalid or missing token");
        out.print(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(result));
        return;
    }

    String action     = p(request, "action");
    String schema     = p(request, "schema");
    String objectName = p(request, "objectName");
    String objectType = p(request, "objectType");
    String dsKey      = p(request, "ds");
    String customUrl  = p(request, "jdbcUrl");
    String customUser = p(request, "dbUser");
    String customPass = p(request, "dbPass");

    String ldapUrl  = p(request,"ldapUrl");  if(ldapUrl.isEmpty())  ldapUrl  = LDAP_URL;
    String ldapBind = p(request,"ldapBind"); if(ldapBind.isEmpty()) ldapBind = LDAP_BIND;
    String ldapPass = p(request,"ldapPass"); if(ldapPass.isEmpty()) ldapPass = LDAP_PASS;
    String ldapBase = p(request,"ldapBase"); if(ldapBase.isEmpty()) ldapBase = LDAP_BASE;

    if (action.isEmpty()) {
        result.put("success", false);
        result.put("error", "Missing 'action' parameter");
        ArrayNode oa = result.putArray("oracleActions");
        for (String a : new String[]{"checkConnection","getSchemas","getTables","getViews","getTableColumns",
            "getTableData","getRowCount","getDDL","getObjectSource","getConstraints","getIndexes",
            "getTableStats","getPartitions","getSequences","getTriggers","getProcedures","getSynonyms",
            "getDbLinks","getMaterializedViews","getTypes","getDatabaseObjects","executeQuery",
            "executeNonQuery","explainPlan","getDependencies","search","getSessionInfo","getTablespaces",
            "getLobData","getPerformance","getStorageInfo"}) oa.add(a);
        ArrayNode la = result.putArray("ldapActions");
        for (String a : new String[]{"ldapCheckConnection","ldapSearch","ldapGetUsers","ldapGetGroups",
            "ldapGetOUs","ldapGetTree","ldapGetEntry"}) la.add(a);
        out.print(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(result));
        return;
    }

    try {
        if (action.startsWith("ldap")) {
            switch (action) {
                case "ldapCheckConnection":
                    result = ldapCheckConnection(ldapUrl, ldapBind, ldapPass); break;
                case "ldapSearch": {
                    String filter = p(request,"filter"); if(filter.isEmpty()) filter="(objectClass=*)";
                    String attrStr = p(request,"attrs");
                    String[] attrs = attrStr.isEmpty()?null:attrStr.split(",");
                    result = ldapSearch(ldapUrl,ldapBind,ldapPass,ldapBase,filter,attrs,
                        pi(request,"scope",SearchControls.SUBTREE_SCOPE),pi(request,"maxResults",200));
                    break;
                }
                case "ldapGetUsers": {
                    String filter = p(request,"filter"); if(filter.isEmpty()) filter="(objectClass=user)";
                    result = ldapSearch(ldapUrl,ldapBind,ldapPass,ldapBase,filter,
                        new String[]{"sAMAccountName","displayName","mail","memberOf","userAccountControl","whenCreated","lastLogon"},
                        SearchControls.SUBTREE_SCOPE,pi(request,"maxResults",200));
                    break;
                }
                case "ldapGetGroups": {
                    String filter = p(request,"filter"); if(filter.isEmpty()) filter="(objectClass=group)";
                    result = ldapSearch(ldapUrl,ldapBind,ldapPass,ldapBase,filter,
                        new String[]{"cn","description","member","groupType","distinguishedName"},
                        SearchControls.SUBTREE_SCOPE,pi(request,"maxResults",200));
                    break;
                }
                case "ldapGetOUs":
                    result = ldapSearch(ldapUrl,ldapBind,ldapPass,ldapBase,"(objectClass=organizationalUnit)",
                        new String[]{"ou","description","distinguishedName"},SearchControls.SUBTREE_SCOPE,pi(request,"maxResults",500));
                    break;
                case "ldapGetTree": {
                    String base = p(request,"baseDN"); if(base.isEmpty()) base=ldapBase;
                    result = ldapGetTree(ldapUrl,ldapBind,ldapPass,base,pi(request,"depth",2));
                    break;
                }
                case "ldapGetEntry": {
                    String dn = p(request,"dn");
                    if(dn.isEmpty()){result.put("success",false);result.put("error","dn required");break;}
                    result = ldapSearch(ldapUrl,ldapBind,ldapPass,dn,"(objectClass=*)",null,SearchControls.OBJECT_SCOPE,1);
                    break;
                }
                default: result = err("Unknown LDAP action: "+action);
            }
            out.print(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(result));
            return;
        }

        Connection conn = null;
        try {
            conn = getConnection(dsKey, customUrl, customUser, customPass);
            switch (action) {
                case "checkConnection":      result = oraCheckConnection(conn); break;
                case "getSchemas":           result = oraGetSchemas(conn); break;
                case "getTables":            result = oraGetTables(conn,schema); break;
                case "getViews":             result = oraGetViews(conn,schema); break;
                case "getTableColumns":      result = oraGetTableColumns(conn,schema,objectName); break;
                case "getTableData":
                    result = oraGetTableData(conn,schema,objectName,
                        pi(request,"page",1),pi(request,"pageSize",200),
                        p(request,"filterCol"),p(request,"filterVal"),
                        p(request,"orderCol"),p(request,"orderDir")); break;
                case "getRowCount":          result = oraGetRowCount(conn,schema,objectName); break;
                case "getDDL":
                    result = oraGetDDL(conn,schema,objectType.isEmpty()?"TABLE":objectType,objectName); break;
                case "getObjectSource":      result = oraGetObjectSource(conn,schema,objectType,objectName); break;
                case "getConstraints":       result = oraGetConstraints(conn,schema,objectName); break;
                case "getIndexes":           result = oraGetIndexes(conn,schema,objectName); break;
                case "getTableStats":        result = oraGetTableStats(conn,schema,objectName); break;
                case "getPartitions":        result = oraGetPartitions(conn,schema,objectName); break;
                case "getSequences":         result = oraGetSequences(conn,schema); break;
                case "getTriggers":          result = oraGetTriggers(conn,schema); break;
                case "getProcedures":        result = oraGetProcedures(conn,schema); break;
                case "getSynonyms":          result = oraGetSynonyms(conn,schema); break;
                case "getDbLinks":           result = oraGetDbLinks(conn,schema); break;
                case "getMaterializedViews": result = oraMaterializedViews(conn,schema); break;
                case "getTypes":             result = oraGetTypes(conn,schema); break;
                case "getDatabaseObjects":   result = oraGetDatabaseObjects(conn,schema,objectType); break;
                case "executeQuery": {
                    String sql=p(request,"query"); if(sql.isEmpty()) sql=p(request,"sql");
                    result = oraExecuteQuery(conn,sql,pi(request,"maxRows",500)); break;
                }
                case "executeNonQuery": {
                    String sql=p(request,"sql"); if(sql.isEmpty()) sql=p(request,"query");
                    result = oraExecuteNonQuery(conn,sql); break;
                }
                case "explainPlan": {
                    String sql=p(request,"query"); if(sql.isEmpty()) sql=p(request,"sql");
                    result = oraExplainPlan(conn,sql); break;
                }
                case "getDependencies":  result = oraGetDependencies(conn,schema,objectName,objectType); break;
                case "search":           result = oraSearch(conn,p(request,"term")); break;
                case "getSessionInfo":   result = oraGetSessionInfo(conn); break;
                case "getTablespaces":   result = oraGetTablespaces(conn); break;
                case "getLobData":       result = oraGetLobData(conn,schema,objectName,p(request,"column"),p(request,"where")); break;
                case "getPerformance":   result = oraGetPerformance(conn); break;
                case "getStorageInfo":   result = oraGetStorageInfo(conn); break;
                default:                 result = err("Unknown action: "+action);
            }
        } finally { close(conn); }

    } catch (Exception ex) {
        result = err(ex.getClass().getSimpleName()+": "+ex.getMessage());
        ArrayNode trace = result.putArray("trace");
        StackTraceElement[] st = ex.getStackTrace();
        for (int i=0;i<Math.min(st.length,4);i++) trace.add(st[i].toString());
    }

    out.print(MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(result));
%>
