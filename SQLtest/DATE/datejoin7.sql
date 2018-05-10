SELECT ZZZ AS PNO, ( SELECT MAX ( QTY )
     FROM   SP 
     WHERE  PNO = ZZZ 
     AND    SNO <> 'S1' ) AS XXX,
     ( SELECT MIN ( QTY )
     FROM   SP 
     WHERE  PNO = ZZZ 
     AND    SNO <> 'S1' ) AS YYY
FROM ( SELECT DISTINCT PNO AS ZZZ
     FROM   SP 
     WHERE  SNO <> 'S1' ) AS POINTLESS
