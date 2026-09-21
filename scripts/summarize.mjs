// Prints, for each live recording of a non-member request, what it did on base and on head.
import fs from 'node:fs';
const dir = new URL('../recordings/', import.meta.url).pathname;
const brief = (p) => {
  if (!fs.existsSync(p)) return 'no recording';
  const a = JSON.parse(fs.readFileSync(p));
  const sql = a.events.filter(e => e.sql_query).map(e => e.sql_query.sql.trim().split(/\s+/).slice(0, 3).join(' ').replace(/"/g, ''));
  const st = a.events.find(e => e.http_server_response)?.http_server_response.status_code;
  const chk = a.events.some(e => e.method_id === 'verifyProjectAccess') ? 'check ran' : 'no check';
  return `${st} | ${chk} | ${sql.join('; ') || 'no SQL'}`;
};
for (const f of fs.readdirSync(dir + 'base').filter(f => /non-member.*\.appmap\.json$/.test(f)).sort()) {
  console.log(f.replace('.appmap.json', ''));
  console.log('   base: ' + brief(dir + 'base/' + f));
  console.log('   head: ' + brief(dir + 'head/' + f));
}
