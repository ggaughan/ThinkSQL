select s, char_length(s) as LENGTH, character_length(trim(s)) as TRIMMED_LENGTH
from CHARTEST 
order by LENGTH DESC
