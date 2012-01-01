%{

{       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
}

{ pascal constants }

const
  llwhere='sqllex.l';
  llwho='';

function install_id:TSyntaxNodePtr; forward;
function install_num:TSyntaxNodePtr; forward;
function install_num_multiplied:TSyntaxNodePtr; forward;
function install_str:TSyntaxNodePtr; forward;
function install_blob:TSyntaxNodePtr; forward;
function install_param:TSyntaxNodePtr; forward;

%}

(* regular definitions *)

(* note: check all [UPPER/lower] are correct and or replace with keyword table *)

delim           [ \t\r\n\f]
ws              {delim}+

us              _
colon           :
digit           [0-9]
alpha           [a-zA-Z]
ch              {digit}|{us}|{alpha}
(*hexit           {digit}|{a-fA-F}*)

badchar         [!£$%^&@~#`|¦¬?\\\[\]]

int_lit         {digit}({digit}|{us})*
int_litK        {int_lit}[kK]
int_litM        {int_lit}[mM]
int_litG        {int_lit}[gG]
real_lit        {int_lit}(\.{int_lit})?([Ee][\+\-]?{int_lit})?
str_lit         \'([^\'\n]|(\'\'))*\'
blob_lit        X{str_lit}({ws}{str_lit})*

label           {alpha}({ch})*{colon}
identifier      {alpha}({ch})*|\"{alpha}({ch})*\"

create          [Cc][Rr][Ee][Aa][Tt][Ee]
schema          [Ss][Cc][Hh][Ee][Mm][Aa]
authorization   [Aa][Uu][Tt][Hh][Oo][Rr][Ii][Zz][Aa][Tt][Ii][Oo][Nn]
global          [Gg][Ll][Oo][Bb][Aa][Ll]
local           [Ll][Oo][Cc][Aa][Ll]
temporary       [Tt][Ee][Mm][Pp][Oo][Rr][Aa][Rr][Yy]
table           [Tt][Aa][Bb][Ll][Ee]
on              [Oo][Nn]
commit          [Cc][Oo][Mm][Mm][Ii][Tt]
delete          [Dd][Ee][Ll][Ee][Tt][Ee]
preserve        [Pp][Rr][Ee][Ss][Ee][Rr][Vv][Ee]
rows            [Rr][Oo][Ww][Ss]
rollback        [Rr][Oo][Ll][Ll][Bb][Aa][Cc][Kk]
work            [Ww][Oo][Rr][Kk]
transaction     [Tt][Rr][Aa][Nn][Ss][Aa][Cc][Tt][Ii][Oo][Nn]
diagnostics     [Dd][Ii][Aa][Gg][Nn][Oo][Ss][Tt][Ii][Cc][Ss]
size            [Ss][Ii][Zz][Ee]
read            [Rr][Ee][Aa][Dd]
only            [Oo][Nn][Ll][Yy]
write           [Ww][Rr][Ii][Tt][Ee]
isolation       [Ii][Ss][Oo][Ll][Aa][Tt][Ii][Oo][Nn]
level           [Ll][Ee][Vv][Ee][Ll]
uncommitted     [Uu][Nn][Cc][Oo][Mm][Mm][Ii][Tt][Tt][Ee][Dd]
committed       [Cc][Oo][Mm][Mm][Ii][Tt][Tt][Ee][Dd]
repeatable      [Rr][Ee][Pp][Ee][Aa][Tt][Aa][Bb][Ll][Ee]
serializable    [Ss][Ee][Rr][Ii][Aa][Ll][Ii][Zz][Aa][Bb][Ll][Ee]
connect         [Cc][Oo][Nn][Nn][Ee][Cc][Tt]
user            [Uu][Ss][Ee][Rr]
current_user    [Cc][Uu][Rr][Rr][Ee][Nn][Tt][_][Uu][Ss][Ee][Rr]
session_user    [Ss][Ee][Ss][Ss][Ii][Oo][Nn][_][Uu][Ss][Ee][Rr]
system_user     [Ss][Yy][Ss][Tt][Ee][Mm][_][Uu][Ss][Ee][Rr]
current_date    [Cc][Uu][Rr][Rr][Ee][Nn][Tt][_][Dd][Aa][Tt][Ee]
current_time    [Cc][Uu][Rr][Rr][Ee][Nn][Tt][_][Tt][Ii][Mm][Ee]
current_timestamp [Cc][Uu][Rr][Rr][Ee][Nn][Tt][_][Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]
password        [Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]
disconnect      [Dd][Ii][Ss][Cc][Oo][Nn][Nn][Ee][Cc][Tt]
current         [Cc][Uu][Rr][Rr][Ee][Nn][Tt]
grant           [Gg][Rr][Aa][Nn][Tt]
privileges      [Pp][Rr][Ii][Vv][Ii][Ll][Ee][Gg][Ee][Ss]
usage           [Uu][Ss][Aa][Gg][Ee]
execute         [Ee][Xx][Ee][Cc][Uu][Tt][Ee]
collation       [Cc][Oo][Ll][Ll][Aa][Tt][Ii][Oo][Nn]
translation     [Tt][Rr][Aa][Nn][Ss][Ll][Aa][Tt][Ii][Oo][Nn]
public          [Pp][Uu][Bb][Ll][Ii][Cc]
revoke          [Rr][Ee][Vv][Oo][Kk][Ee]
for             [Ff][Oo][Rr]
drop            [Dd][Rr][Oo][Pp]
alter           [Aa][Ll][Tt][Ee][Rr]
add             [Aa][Dd][Dd]
column          [Cc][Oo][Ll][Uu][Mm][Nn]

showtrans       [Ss][Hh][Oo][Ww][Tt][Rr][Aa][Nn][Ss]
shutdown        [Ss][Hh][Uu][Tt][Dd][Oo][Ww][Nn]

select          [Ss][Ee][Ll][Ee][Cc][Tt]
as              [Aa][Ss]
all             [Aa][Ll][Ll]
distinct        [Dd][Ii][Ss][Tt][Ii][Nn][Cc][Tt]
into            [Ii][Nn][Tt][Oo]
from            [Ff][Rr][Oo][Mm]
where           [Ww][Hh][Ee][Rr][Ee]
group           [Gg][Rr][Oo][Uu][Pp]
by              [Bb][Yy]
order           [Oo][Rr][Dd][Ee][Rr]
asc             [Aa][Ss][Cc]
desc            [Dd][Ee][Ss][Cc]
having          [Hh][Aa][Vv][Ii][Nn][Gg]

avg             [Aa][Vv][Gg]
max             [Mm][Aa][Xx]
min             [Mm][Ii][Nn]
sum             [Ss][Uu][Mm]
count           [Cc][Oo][Uu][Nn][Tt]

to              [Tt][Oo]
at              [Aa][Tt]
time            [Tt][Ii][Mm][Ee]
zone            [Zz][Oo][Nn][Ee]

or              [Oo][Rr]
and             [Aa][Nn][Dd]
not             [Nn][Oo][Tt]
is              [Ii][Ss]
true            [Tt][Rr][Uu][Ee]
false           [Ff][Aa][Ll][Ss][Ee]
unknown         [Uu][Nn][Kk][Nn][Oo][Ww][Nn]
between         [Bb][Ee][Tt][Ww][Ee][Ee][Nn]
like            [Ll][Ii][Kk][Ee]
escape          [Ee][Ss][Cc][Aa][Pp][Ee]
in              [Ii][Nn]
match           [Mm][Aa][Tt][Cc][Hh]
unique          [Uu][Nn][Ii][Qq][Uu][Ee]
partial         [Pp][Aa][Rr][Tt][Ii][Aa][Ll]
full            [Ff][Uu][Ll][Ll]
any             [Aa][Nn][Yy]
some            [Ss][Oo][Mm][Ee]
exists          [Ee][Xx][Ii][Ss][Tt][Ss]
overlaps        [Oo][Vv][Ee][Rr][Ll][Aa][Pp][Ss]
null            [Nn][Uu][Ll][Ll]
param           [?]

constraint      [Cc][Oo][Nn][Ss][Tt][Rr][Aa][Ii][Nn][Tt]
primary         [Pp][Rr][Ii][Mm][Aa][Rr][Yy]
key             [Kk][Ee][Yy]
foreign         [Ff][Oo][Rr][Ee][Ii][Gg][Nn]
references      [Rr][Ee][Ff][Ee][Rr][Ee][Nn][Cc][Ee][Ss]
update          [Uu][Pp][Dd][Aa][Tt][Ee]
no              [Nn][Oo]
action          [Aa][Cc][Tt][Ii][Oo][Nn]
cascade         [Cc][Aa][Ss][Cc][Aa][Dd][Ee]
restrict        [Rr][Ee][Ss][Tt][Rr][Ii][Cc][Tt]
set             [Ss][Ee][Tt]
default         [Dd][Ee][Ff][Aa][Uu][Ll][Tt]
check           [Cc][Hh][Ee][Cc][Kk]
domain          [Dd][Oo][Mm][Aa][Ii][Nn]
initially       [Ii][Nn][Ii][Tt][Ii][Aa][Ll][Ll][Yy]
deferred        [Dd][Ee][Ff][Ee][Rr][Rr][Ee][Dd]
immediate       [Ii][Mm][Mm][Ee][Dd][Ii][Aa][Tt][Ee]
deferrable      [Dd][Ee][Ff][Ee][Rr][Rr][Aa][Bb][Ll][Ee]
constraints     [Cc][Oo][Nn][Ss][Tt][Rr][Aa][Ii][Nn][Tt][Ss]

view            [Vv][Ii][Ee][Ww]
with            [Ww][Ii][Tt][Hh]
cascaded        [Cc][Aa][Ss][Cc][Aa][Dd][Ee][Dd]
option          [Oo][Pp][Tt][Ii][Oo][Nn]

out             [Oo][Uu][Tt]
inout           [Ii][Nn][Oo][Uu][Tt]
returns         [Rr][Ee][Tt][Uu][Rr][Nn][Ss]
procedure       [Pp][Rr][Oo][Cc][Ee][Dd][Uu][Rr][Ee]
function        [Ff][Uu][Nn][Cc][Tt][Ii][Oo][Nn]
routine         [Rr][Oo][Uu][Tt][Ii][Nn][Ee]
call            [Cc][Aa][Ll][Ll]
declare         [Dd][Ee][Cc][Ll][Aa][Rr][Ee]
return          [Rr][Ee][Tt][Uu][Rr][Nn]

cursor          [Cc][Uu][Rr][Ss][Oo][Rr]
of              [Oo][Ff]
sensitive       [Ss][Ee][Nn][Ss][Ii][Tt][Ii][Vv][Ee]
insensitive     [Ii][Nn][Ss][Ee][Nn][Ss][Ii][Tt][Ii][Vv][Ee]
asensitive      [Aa][Ss][Ee][Nn][Ss][Ii][Tt][Ii][Vv][Ee]
scroll          [Ss][Cc][Rr][Oo][Ll][Ll]
hold            [Hh][Oo][Ll][Dd]
open            [Oo][Pp][Ee][Nn]
close           [Cc][Ll][Oo][Ss][Ee]
fetch           [Ff][Ee][Tt][Cc][Hh]
next            [Nn][Ee][Xx][Tt]
prior           [Pp][Rr][Ii][Oo][Rr]
first           [Ff][Ii][Rr][Ss][Tt]
last            [Ll][Aa][Ss][Tt]
absolute        [Aa][Bb][Ss][Oo][Ll][Uu][Tt][Ee]
relative        [Rr][Ee][Ll][Aa][Tt][Ii][Vv][Ee]
sqlstate        [Ss][Qq][Ll][Ss][Tt][Aa][Tt][Ee]

insert          [Ii][Nn][Ss][Ee][Rr][Tt]
values          [Vv][Aa][Ll][Uu][Ee][Ss]

cross           [Cc][Rr][Oo][Ss][Ss]
join            [Jj][Oo][Ii][Nn]
natural         [Nn][Aa][Tt][Uu][Rr][Aa][Ll]
using           [Uu][Ss][Ii][Nn][Gg]
inner           [Ii][Nn][Nn][Ee][Rr]
outer           [Oo][Uu][Tt][Ee][Rr]
left            [Ll][Ee][Ff][Tt]
right           [Rr][Ii][Gg][Hh][Tt]
union           [Uu][Nn][Ii][Oo][Nn]
except          [Ee][Xx][Cc][Ee][Pp][Tt]
intersect       [Ii][Nn][Tt][Ee][Rr][Ss][Ee][Cc][Tt]
corresponding   [Cc][Oo][Rr][Rr][Ee][Ss][Pp][Oo][Nn][Dd][Ii][Nn][Gg]

integer         [Ii][Nn][Tt][Ee][Gg][Ee][Rr]
int             [Ii][Nn][Tt]
smallint        [Ss][Mm][Aa][Ll][Ll][Ii][Nn][Tt]
bigint          [Bb][Ii][Gg][Ii][Nn][Tt]
float           [Ff][Ll][Oo][Aa][Tt]
real            [Rr][Ee][Aa][Ll]
double          [Dd][Oo][Uu][Bb][Ll][Ee]
precision       [Pp][Rr][Ee][Cc][Ii][Ss][Ii][Oo][Nn]
numeric         [Nn][Uu][Mm][Ee][Rr][Ii][Cc]
decimal         [Dd][Ee][Cc][Ii][Mm][Aa][Ll]
dec             [Dd][Ee][Cc]
character       [Cc][Hh][Aa][Rr][Aa][Cc][Tt][Ee][Rr]
char            [Cc][Hh][Aa][Rr]
varying         [Vv][Aa][Rr][Yy][Ii][Nn][Gg]
varchar         [Vv][Aa][Rr][Cc][Hh][Aa][Rr]
bit             [Bb][Ii][Tt]
date            [Dd][Aa][Tt][Ee]
timestamp       [Tt][Ii][Mm][Ee][Ss][Tt][Aa][Mm][Pp]
interval        [Ii][Nn][Tt][Ee][Rr][Vv][Aa][Ll]
blob            [Bb][Ll][Oo][Bb]
clob            [Cc][Ll][Oo][Bb]
binary          [Bb][Ii][Nn][Aa][Rr][Yy]
large           [Ll][Aa][Rr][Gg][Ee]
object          [Oo][Bb][Jj][Ee][Cc][Tt]

case            [Cc][Aa][Ss][Ee]
when            [Ww][Hh][Ee][Nn]
then            [Tt][Hh][Ee][Nn]
else            [Ee][Ll][Ss][Ee]
end             [Ee][Nn][Dd]
coalesce        [Cc][Oo][Aa][Ll][Ee][Ss][Cc][Ee]
nullif          [Nn][Uu][Ll][Ll][Ii][Ff]

trim            [Tt][Rr][Ii][Mm]
leading         [Ll][Ee][Aa][Dd][Ii][Nn][Gg]
trailing        [Tt][Rr][Aa][Ii][Ll][Ii][Nn][Gg]
both            [Bb][Oo][Tt][Hh]

character_length [Cc][Hh][Aa][Rr][Aa][Cc][Tt][Ee][Rr][_][Ll][Ee][Nn][Gg][Tt][Hh]
char_length     [Cc][Hh][Aa][Rr][_][Ll][Ee][Nn][Gg][Tt][Hh]
octet_length    [Oo][Cc][Tt][Ee][Tt][_][Ll][Ee][Nn][Gg][Tt][Hh]

lower           [Ll][Oo][Ww][Ee][Rr]
upper           [Uu][Pp][Pp][Ee][Rr]
position        [Pp][Oo][Ss][Ii][Tt][Ii][Oo][Nn]
substring       [Ss][Uu][Bb][Ss][Tt][Rr][Ii][Nn][Gg]
cast            [Cc][Aa][Ss][Tt]

begin           [Bb][Ee][Gg][Ii][Nn]
atomic          [Aa][Tt][Oo][Mm][Ii][Cc]
while           [Ww][Hh][Ii][Ll][Ee]
do              [Dd][Oo]
if              [Ii][Ff]
elseif          [Ee][Ll][Ss][Ee][Ii][Ff]
leave           [Ll][Ee][Aa][Vv][Ee]
iterate         [Ii][Tt][Ee][Rr][Aa][Tt][Ee]
loop            [Ll][Oo][Oo][Pp]
repeat          [Rr][Ee][Pp][Ee][Aa][Tt]
until           [Uu][Nn][Tt][Ii][Ll]

(* Non SQL/92 (implementation-defined) keywords *)
catalog         [Cc][Aa][Tt][Aa][Ll][Oo][Gg]
debug           [Dd][Ee][Bb][Uu][Gg]
index           [Ii][Nn][Dd][Ee][Xx]
summary         [Ss][Uu][Mm][Mm][Aa][Rr][Yy]
server          [Ss][Ee][Rr][Vv][Ee][Rr]
page            [Pp][Aa][Gg][Ee]
plan            [Pp][Ll][Aa][Nn]
print           [Pp][Rr][Ii][Nn][Tt]
sequence        [Ss][Ee][Qq][Uu][Ee][Nn][Cc][Ee]
next_sequence   [Nn][Ee][Xx][Tt][_][Ss][Ee][Qq][Uu][Ee][Nn][Cc][Ee]
latest_sequence [Ll][Aa][Tt][Ee][Ss][Tt][_][Ss][Ee][Qq][Uu][Ee][Nn][Cc][Ee]
starting        [Ss][Tt][Aa][Rr][Tt][Ii][Nn][Gg]
kill            [Kk][Ii][Ll][Ll]
cancel          [Cc][Aa][Nn][Cc][Ee][Ll]
rebuild         [Rr][Ee][Bb][Uu][Ii][Ll][Dd]
backup          [Bb][Aa][Cc][Kk][Uu][Pp]
garbage         [Gg][Aa][Rr][Bb][Aa][Gg][Ee]
collect         [Cc][Oo][Ll][Ll][Ee][Cc][Tt]

current_authid  [Cc][Uu][Rr][Rr][Ee][Nn][Tt][_][Aa][Uu][Tt][Hh][Ii][Dd]
current_catalog [Cc][Uu][Rr][Rr][Ee][Nn][Tt][_][Cc][Aa][Tt][Aa][Ll][Oo][Gg]
current_schema  [Cc][Uu][Rr][Rr][Ee][Nn][Tt][_][Ss][Cc][Hh][Ee][Mm][Aa]

(* SQL/92 reserved words not yet implemented *)
allocate        [Aa][Ll][Ll][Oo][Cc][Aa][Tt][Ee]
are             [Aa][Rr][Ee]
assertion       [Aa][Ss][Ss][Ee][Rr][Tt][Ii][Oo][Nn]
bit_length      [Bb][Ii][Tt][_][Ll][Ee][Nn][Gg][Tt][Hh]
collate         [Cc][Oo][Ll][Ll][Aa][Tt][Ee]
(* ... etc... *)

%%

{ws}            ; //no action & no return
{create}        return(kwCREATE);
{schema}        return(kwSCHEMA);
{authorization} return(kwAUTHORIZATION);
{global}        return(kwGLOBAL);
{local}         return(kwLOCAL);
{temporary}     return(kwTEMPORARY);
{table}         return(kwTABLE);
{on}            return(kwON);
{commit}        return(kwCOMMIT);
{delete}        return(kwDELETE);
{preserve}      return(kwPRESERVE);
{rows}          return(kwROWS);
{rollback}      return(kwROLLBACK);
{work}          return(kwWORK);
{transaction}   return(kwTRANSACTION);
{diagnostics}   return(kwDIAGNOSTICS);
{size}          return(kwSIZE);
{read}          return(kwREAD);
{only}          return(kwONLY);
{write}         return(kwWRITE);
{isolation}     return(kwISOLATION);
{level}         return(kwLEVEL);
{uncommitted}   return(kwUNCOMMITTED);
{committed}     return(kwCOMMITTED);
{repeatable}    return(kwREPEATABLE);
{serializable}  return(kwSERIALIZABLE);
{connect}       return(kwCONNECT);
{user}          return(kwUSER);
{current_user}  return(kwCURRENT_USER);
{session_user}  return(kwSESSION_USER);
{system_user}   return(kwSYSTEM_USER);
{current_date}  return(kwCURRENT_DATE);
{current_time}  return(kwCURRENT_TIME);
{current_timestamp} return(kwCURRENT_TIMESTAMP);
{password}      return(kwPASSWORD);
{disconnect}    return(kwDISCONNECT);
{current}       return(kwCURRENT);
{grant}         return(kwGRANT);
{privileges}    return(kwPRIVILEGES);
{usage}         return(kwUSAGE);
{execute}       return(kwEXECUTE);
{collation}     return(kwCOLLATION);
{translation}   return(kwTRANSLATION);
{public}        return(kwPUBLIC);
{revoke}        return(kwREVOKE);
{for}           return(kwFOR);
{drop}          return(kwDROP);
{alter}         return(kwALTER);
{add}           return(kwADD);
{column}        return(kwCOLUMN);


{catalog}       return(kwCATALOG);   //Non SQL/92 implementation-defined keyword
{debug}         return(kwDEBUG);     //DEBUG ONLY!   //TODO REMOVE!
{index}         return(kwINDEX);     //DEBUG ONLY!   //TODO REMOVE!
{summary}       return(kwSUMMARY);   //DEBUG ONLY!   //TODO REMOVE!
{server}        return(kwSERVER);    //DEBUG ONLY!   //TODO REMOVE!
{page}          return(kwPAGE);      //DEBUG ONLY!   //TODO REMOVE!
{plan}          return(kwPLAN);      //DEBUG ONLY!   //TODO REMOVE!
{print}         return(kwPRINT);     //DEBUG ONLY!   //TODO REMOVE!
{sequence}      return(kwSEQUENCE);  //Non SQL/92 implementation-defined keyword
{next_sequence} return(kwNEXT_SEQUENCE);     //Non SQL/92 implementation-defined keyword
{latest_sequence} return(kwLATEST_SEQUENCE);     //Non SQL/92 implementation-defined keyword
{starting}      return(kwSTARTING);  //Non SQL/92 implementation-defined keyword
{kill}          return(kwKILL);      //Non SQL/92 implementation-defined keyword
{cancel}        return(kwCANCEL);    //Non SQL/92 implementation-defined keyword
{rebuild}       return(kwREBUILD);   //DEBUG ONLY!   //TODO REMOVE!
{backup}        return(kwBACKUP);    //Non SQL/92 implementation-defined keyword
{garbage}       return(kwGARBAGE);   //Non SQL/92 implementation-defined keyword
{collect}       return(kwCOLLECT);   //Non SQL/92 implementation-defined keyword

{showtrans}     return(kwSHOWTRANS); //DEBUG ONLY!   //TODO REMOVE!
{shutdown}      return(kwSHUTDOWN);  //DEBUG ONLY!   //TODO REMOVE!?

{current_authid}  return(kwCURRENT_AUTHID);  //Non SQL/92 implementation-defined keyword
{current_catalog} return(kwCURRENT_CATALOG); //Non SQL/92 implementation-defined keyword
{current_schema}  return(kwCURRENT_SCHEMA);  //Non SQL/92 implementation-defined keyword


{select}        return(kwSELECT);
{as}            return(kwAS);
{all}           return(kwALL);
{distinct}      return(kwDISTINCT);
{into}          return(kwINTO);
{from}          return(kwFROM);
{where}         return(kwWHERE);
{group}         return(kwGROUP);
{by}            return(kwBY);
{order}         return(kwORDER);
{asc}           return(kwASC);
{desc}          return(kwDESC);
{having}        return(kwHAVING);

{avg}           return(kwAVG);
{max}           return(kwMAX);
{min}           return(kwMIN);
{sum}           return(kwSUM);
{count}         return(kwCOUNT);

{to}            return(kwTO);
{at}            return(kwAT); //used currently for non-SQL sequence starting, but is reserved
{or}            return(kwOR);
{and}           return(kwAND);
{not}           return(kwNOT);
{is}            return(kwIS);
{true}          return(kwTRUE);
{false}         return(kwFALSE);
{unknown}       return(kwUNKNOWN);
{between}       return(kwBETWEEN);
{like}          return(kwLIKE);
{escape}        return(kwESCAPE);
{in}            return(kwIN);
{match}         return(kwMATCH);
{unique}        return(kwUNIQUE);
{partial}       return(kwPARTIAL);
{full}          return(kwFULL);
{any}           return(kwANY);
{some}          return(kwSOME);
{exists}        return(kwEXISTS);
{overlaps}      return(kwOVERLAPS);

{constraint}    return(kwCONSTRAINT);
{primary}       return(kwPRIMARY);
{key}           return(kwKEY);
{foreign}       return(kwFOREIGN);
{references}    return(kwREFERENCES);
{update}        return(kwUPDATE);
{no}            return(kwNO);
{action}        return(kwACTION);
{cascade}       return(kwCASCADE);
{restrict}      return(kwRESTRICT);
{set}           return(kwSET);
{default}       return(kwDEFAULT);
{check}         begin
                  {we may need to capture the raw text if this is to be a check constraint}
                  check_start_text:=GlobalParseStmt.InputText; {todo maybe limit this?}
                  check_start_at:=yyOffset;
                  return(kwCHECK);
                end;
{domain}        return(kwDOMAIN);
{initially}     return(kwINITIALLY);
{deferred}      return(kwDEFERRED);
{immediate}     return(kwIMMEDIATE);
{deferrable}    return(kwDEFERRABLE);
{constraints}   return(kwCONSTRAINTS);

{view}          begin
                  {we may need to capture the raw text if this is to be a view definition}
                  {note: rename this variables - used for more than one thing!}
                  check_start_text:=GlobalParseStmt.InputText; {todo maybe limit this?}
                  check_start_at:=yyOffset;
                  return(kwVIEW);
                end;
{with}          return(kwWITH);
{cascaded}      return(kwCASCADED);
{option}        return(kwOPTION);

{out}           return(kwOUT);
{inout}         return(kwINOUT);
{returns}       return(kwRETURNS);
{procedure}     begin
                  {we may need to capture the raw text if this is to be a procedure definition}
                  {note: rename this variables - used for more than one thing!}
                  check_start_text:=GlobalParseStmt.InputText; {todo maybe limit this?}
                  check_start_at:=yyOffset;
                  return(kwPROCEDURE);
                end;
{function}      begin
                  {we may need to capture the raw text if this is to be a procedure definition}
                  {note: rename this variables - used for more than one thing!}
                  check_start_text:=GlobalParseStmt.InputText; {todo maybe limit this?}
                  check_start_at:=yyOffset;
                  return(kwFUNCTION);
                end;
{routine}       return(kwROUTINE);
{call}          return(kwCALL);
{declare}       return(kwDECLARE);
{return}        return(kwRETURN);

{cursor}        return(kwCURSOR);
{of}            return(kwOF);
{sensitive}     return(kwSENSITIVE);
{insensitive}   return(kwINSENSITIVE);
{asensitive}    return(kwASENSITIVE);
{scroll}        return(kwSCROLL);
{hold}          return(kwHOLD);
{open}          return(kwOPEN);
{close}         return(kwCLOSE);
{fetch}         return(kwFETCH);
{next}          return(kwNEXT);
{prior}         return(kwPRIOR);
{first}         return(kwFIRST);
{last}          return(kwLAST);
{absolute}      return(kwABSOLUTE);
{relative}      return(kwRELATIVE);
{sqlstate}      return(kwSQLSTATE);

{insert}        return(kwINSERT);
{values}        return(kwVALUES);

{cross}         return(kwCROSS);
{join}          return(kwJOIN);
{natural}       return(kwNATURAL);
{using}         return(kwUSING);
{inner}         return(kwINNER);
{outer}         return(kwOUTER);
{left}          return(kwLEFT);
{right}         return(kwRIGHT);
{union}         return(kwUNION);
{except}        return(kwEXCEPT);
{intersect}     return(kwINTERSECT);
{corresponding} return(kwCORRESPONDING);


{integer}       return(kwINTEGER);
{int}           return(kwINT);
{smallint}      return(kwSMALLINT);
{bigint}        return(kwBIGINT);
{float}         return(kwFLOAT);
{real}          return(kwREAL);
{double}        return(kwDOUBLE);
{precision}     return(kwPRECISION);
{numeric}       return(kwNUMERIC);
{decimal}       return(kwDECIMAL);
{dec}           return(kwDEC);
{character}     return(kwCHARACTER);
{char}          return(kwCHAR);
{varying}       return(kwVARYING);
{varchar}       return(kwVARCHAR);
{bit}           return(kwBIT);
{date}          return(kwDATE);
{time}          return(kwTIME);
{timestamp}     return(kwTIMESTAMP);
{zone}          return(kwZONE);
{interval}      return(kwINTERVAL);
{blob}          return(kwBLOB);
{clob}          return(kwCLOB);
{binary}        return(kwBINARY);
{large}         return(kwLARGE);
{object}        return(kwOBJECT);

{case}          return(kwCASE);
{when}          return(kwWHEN);
{then}          return(kwTHEN);
{else}          return(kwELSE);
{end}           return(kwEND);
{coalesce}      return(kwCOALESCE);
{nullif}        return(kwNULLIF);

{trim}          return(kwTRIM);
{leading}       return(kwLEADING);
{trailing}      return(kwTRAILING);
{both}          return(kwBOTH);

{character_length} return(kwCHARACTER_LENGTH);
{char_length}   return(kwCHAR_LENGTH);
{octet_length}  return(kwOCTET_LENGTH);

{lower}         return(kwLOWER);
{upper}         return(kwUPPER);
{position}      return(kwPOSITION);
{substring}     return(kwSUBSTRING);
{cast}          return(kwCAST);

{begin}         return(kwBEGIN);
{atomic}        return(kwATOMIC);
{while}         return(kwWHILE);
{do}            return(kwDO);
{if}            return(kwIF);
{elseif}        return(kwELSEIF);
{leave}         return(kwLEAVE);
{iterate}       return(kwITERATE);
{loop}          return(kwLOOP);
{repeat}        return(kwREPEAT);
{until}         return(kwUNTIL);

"("             return(pLPAREN);
")"             return(pRPAREN);
","             return(pCOMMA);
"."             return(pDOT);
"*"             return(pASTERISK);
"/"             return(pSLASH);
"+"             return(pPLUS);
"-"             return(pMINUS);
";"             return(pSEMICOLON);
"||"            return(pCONCAT);
"="             return(pEQUAL);
"<"             return(pLT);
"<="            return(pLTEQ);
">"             return(pGT);
">="            return(pGTEQ);
"<>"            return(pNOTEQUAL);

"--".*          ; { comment }

{null}          return(kwNULL);

{param}         begin yylval:=install_param; return(tPARAM); end;

{int_lit}       begin yylval:=install_num; if yylval=nil then return(LEXERROR) else return(tINTEGER); end;
{int_litK}      begin yylval:=install_num_multiplied; if yylval=nil then return(LEXERROR) else return(tINTEGER); end;
{int_litM}      begin yylval:=install_num_multiplied; if yylval=nil then return(LEXERROR) else return(tINTEGER); end;
{int_litG}      begin yylval:=install_num_multiplied; if yylval=nil then return(LEXERROR) else return(tINTEGER); end;
{real_lit}      begin yylval:=install_num; if yylval=nil then return(LEXERROR) else return(tREAL); end;
{str_lit}       begin yylval:=install_str; return(tSTRING); end;
{blob_lit}      begin yylval:=install_blob; if yylval=nil then return(LEXERROR) else return(tBLOB); end;
{identifier}    begin
                  {note: we need a way of distinguishing between column id's and others}
                  yylval:=install_id;
                  return(tIDENTIFIER);
                end;
{label}         begin
                  yylval:=install_id;
                  return(tLABEL);
                end;


\'([^\'\n]|(\'\'))*$    return(LEXERROR); {Unterminated string}
{badchar}               return(LEXERROR); {Invalid character}

%%

var
  //note: we need to reset these before each parse! (especially param_count - yyparse caller currently does this)
  id_count, num_count, str_count, param_count, blob_count:integer;

function install_id:TSyntaxNodePtr;
const routine=':install_id';
var
  n:TSyntaxNodePtr;
begin
  inc(id_count);
  n:=mkLeaf(GlobalParseStmt.srootAlloc,ntId,ctUnknown,0,0);
  {Note: we currently delay catalog type checking until we evaluate the
   column references. So, the grammar is lax and will match based on
   lexical items other than 'column'. This should be good enough, providing
   we handle the type-changes at evaluation time.
  }
  n.idVal:=yytext;
  {if this is a quoted identifier, they've done their job because we're here, so remove the quotes for the server}
  if (copy(n.idVal,1,1)='"') and (copy(n.idVal,length(n.idVal),1)='"') then
    n.idVal:=copy(n.idVal,2,length(n.idVal)-2);
  n.nullVal:=false;
  n.line:=yylineno;
  n.col:=yycolno;
  result:=n;
  //yytext, yyleng
  {$IFDEF DEBUG_LOG}
  log.add(llwho,llwhere+routine,format('Installing id %d=%s',[id_count,yytext]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}
end;


function getPrecision(s:string):integer;
var i:integer;
begin
  //note: improve- format to canonical form first
  s:=trim(s);
  i:=pos('.',s);
  if i=0 then
    result:=length(s)
  else
    result:=length(s)-1;
  i:=pos('-',s);
  if i<>0 then
    result:=result-1;
end; {getPrecision}
function getScale(s:string):integer;
var i:integer;
begin
  //note: improve- format to canonical form first
  s:=trim(s);
  i:=pos('.',s);
  if i=0 then
    result:=0
  else
    result:=length(s)-i;
end; {getScale}
function install_num:TSyntaxNodePtr;
{Assumes DecimalSeparator has been forced to '.'
 Result= nil=> fail
}
const routine=':install_num';
var
  n:TSyntaxNodePtr;
  d:double;
begin
  {Adjust the value for storage}
  try
    d:=StrToFloat(yytext)*power(10,GetScale(yytext)); //i.e. shift scale decimal places to the left
  except
    result:=nil;
    exit;
  end; {try}

  inc(num_count);
  n:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,GetPrecision(yytext),GetScale(yytext));
  n.numVal:=trunc(d); //note: trunc is overkill but it makes it clearer what's happening
  n.nullVal:=false;
  n.line:=yylineno;
  n.col:=yycolno;
  result:=n;
  {$IFDEF DEBUG_LOG}
  log.add(llwho,llwhere+routine,format('Installing num %d=%s',[num_count,yytext]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}
end;

function install_num_multiplied:TSyntaxNodePtr;
{Expects last character to be K, M or G and to use this to multiply the number

 Assumes DecimalSeparator has been forced to '.'
 Result= nil=> fail
}
const routine=':install_num_multiplied';
var
  n:TSyntaxNodePtr;
  d:double;
  s:string;
begin
  {Adjust the value for storage}
  s:=copy(yytext,1,length(yytext)-1);
  try
    d:=StrToFloat(s)*power(10,GetScale(s)); //i.e. shift scale decimal places to the left
  except
    result:=nil;
    exit;
  end; {try}

  inc(num_count);
  n:=mkLeaf(GlobalParseStmt.srootAlloc,ntNumber,ctNumeric,GetPrecision(s),GetScale(copy(yytext,1,length(s)-1)));
  n.numVal:=trunc(d); //note: trunc is overkill but it makes it clearer what's happening
  s:=copy(yytext,length(yytext),1); //now look at multiplier
  if (s='k') or (s='K') then n.numVal:=n.numVal*1024;
  if (s='m') or (s='M') then n.numVal:=n.numVal*1048576;
  if (s='g') or (s='G') then n.numVal:=n.numVal*1073741824;
  n.nullVal:=false;
  n.line:=yylineno;
  n.col:=yycolno;
  result:=n;
  {$IFDEF DEBUG_LOG}
  log.add(llwho,llwhere+routine,format('Installing num %d=%s',[num_count,yytext]),vDebug);
  {$ENDIF}
end;

function install_str:TSyntaxNodePtr;
const routine=':install_str';
var
  n:TSyntaxNodePtr;
  i,upto:integer;
  s,sQuotesOk:string;
begin
  inc(str_count);
  n:=mkLeaf(GlobalParseStmt.srootAlloc,ntString,ctVarChar,0{deferred until below},0);

  s:=copy(yytext,2,length(yytext)-2); //remove outer quotes

  {Fix single quotes}
  //note: fixed bug where we can't embed multiple quotes,e.g. 'test''''ing' -> 'test'ing' =bad
  //note: there's probably a faster, less fragmentory algorithm! - can't lex do the hard work?
  sQuotesOk:='';
  i:=pos('''''',s); //find ''
  while i>0 do
  begin
    sQuotesOk:=sQuotesOk+copy(s,1,i); //include 1st quote, but not second: i.e. reduce '' to '

    s:=copy(s,i+2,length(s)); //next search is only in remainder, i.e. skip this pair

    i:=pos('''''',s);
  end;
  sQuotesOk:=sQuotesOk+copy(s,1,length(s)); //whatever's left (in most cases this will be all of s)

  n.strVal:=sQuotesOk;

  n.dWidth:=length(n.strVal);

  n.nullVal:=false;
  n.line:=yylineno;
  n.col:=yycolno;
  result:=n;
  {$IFDEF DEBUG_LOG}
  log.add(llwho,llwhere+routine,format('Installing str %d=%s',[str_count,n.strVal]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}
end;

function install_blob:TSyntaxNodePtr;
const routine=':install_blob';
var
  n:TSyntaxNodePtr;
  i,blobsize:cardinal;
  s,sQuotesOk:string;
begin
  s:=copy(yytext,3,length(yytext)-3); //remove X & outer quotes

  {Remove single quotes and whitespace to enable 'ABC''DEF' to represent 'ABCDEF'}
  //note: there's probably a faster, less fragmentory algorithm! - can't lex do the hard work?
  s:=StringReplace(s,' ','',[rfReplaceAll]);
  s:=StringReplace(s,#9,'',[rfReplaceAll]);
  s:=StringReplace(s,#10,'',[rfReplaceAll]);
  s:=StringReplace(s,#13,'',[rfReplaceAll]);  //note: should strictly do all {delim}, i.e. including formfeed
  s:=StringReplace(s,'''''','',[rfReplaceAll]);

  {Now convert from hex to octets, e.g. FF=#255, to take up half the space
   -note: we may have to defer this until later if 00 becomes a problem...}
  sQuotesOk:='';
  blobsize:=(length(s)+1) div 2;
  {$IFDEF DEBUG_LOG}
  log.add(llwho,llwhere+routine,format('Installing blob with length=%d',[blobsize]),vDebug);
  {$ENDIF}
  //note: speed improvement: setLength(sQuotesOk,blobsize);
  try
    for i:=1 to length(s) div 2 do
    begin
      {$IFDEF DEBUG_LOG}
      if copy(s,(i*2)-1,2)='00' then
        log.add(llwho,llwhere+routine,format('Warning: Installing blob with 00 at %d',[(i*2)-1]),vDebug);
      {$ENDIF}
      sQuotesOk:=sQuotesOk+chr(strToInt('$'+copy(s,(i*2)-1,2))); //note: what if = chr(0) => end of string? use array!
    end;
    if odd(length(s)) then
    begin //get final hexit
      {$IFDEF DEBUG_LOG}
      if copy(s,length(s),1)='0' then
        log.add(llwho,llwhere+routine,format('Warning: Installing blob with final 0 which may be lost?',[nil]),vDebug);
      {$ENDIF}
      sQuotesOk:=sQuotesOk+chr(strToInt('$'+copy(s,length(s),1)));
    end;
  except
    result:=nil;
    exit;
  end; {try}

  inc(blob_count);
  n:=mkLeaf(GlobalParseStmt.srootAlloc,ntBlob,ctBlob{could be ctClob},0{deferred until below},0); //blob_count str_count;

  setLength(n.strVal,blobsize); //speed & avoid chr(0) prematurely ending string
  n.strVal:=sQuotesOk; //note: use move to avoid chr(0) prematurely ending string?
  n.numVal:=blobsize; 

  n.dWidth:=trunc(n.numVal);

  n.nullVal:=false;
  n.line:=yylineno;
  n.col:=yycolno;
  result:=n;
  {$IFDEF DEBUG_LOG}
  log.add(llwho,llwhere+routine,format('Installing blob %d=%s',[blob_count,n.strVal]),vDebug);
  {$ENDIF}
end;

function install_param:TSyntaxNodePtr;
const routine=':install_param';
var
  n:TSyntaxNodePtr;
begin
  inc(param_count);
  n:=mkLeaf(GlobalParseStmt.srootAlloc,ntParam,ctVarChar{note: should be ctUnknown, but auto-populate IPD is limited for now!},0,0);
  {Note: since we delay parameter type checking until we are given the
   values, the grammar is lax and the type is ctUnknown.
  }
  n.idVal:=intToStr(param_count); //store the param number here for matching later //yytext; //may be useful for future named parameters
  n.nullVal:=false;
  n.strVal:='?'; //note: make ?='not-passed-value-yet' constant
                 //we must use another flag for this test: else user can't pass ? into a parameter!!!!!******
                 //note: this is reset in Tstmt.resetParamList
  n.line:=yylineno;
  n.col:=yycolno;
  result:=n;
  {$IFDEF DEBUG_LOG}
  log.add(llwho,llwhere+routine,format('Installing param %d=%s',[param_count,n.idVal]),vDebug);
  {$ELSE}
  ;
  {$ENDIF}
end;


