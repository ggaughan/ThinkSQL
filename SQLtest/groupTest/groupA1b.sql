SELECT
 A1.Descrizione,SUM(A1.Qty)-
(SELECT SUM(A2.Qty)
FROM A2
WHERE A2.Descrizione = A1.Descrizione)
FROM A1
where A1.descrizione = 'Mele'
GROUP BY A1.Descrizione;