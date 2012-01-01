{Yacc Library
}

{$I-}

unit yacclib;

interface

const yymaxdepth = 16384; //Greg Gaughan: 21/01/03 8192; //Greg: 04/02/01 4096 //Greg: 04/10/00: 1024;
  (* default stack size of parser *)

type YYSType = Integer;
  (* default value type, may be redefined in Yacc output file *)

var

yychar   : Integer; (* current lookahead character *)
yynerrs  : Integer; (* current number of syntax errors reported by the
                       parser *)
yydebug  : Boolean; (* set to true to enable debugging output of parser *)

procedure yyerror ( msg : String );
  (* error message printing routine used by the parser *)

procedure yyclearin;
  (* delete the current lookahead token *)

procedure yyaccept;
  (* trigger accept action of the parser; yyparse accepts returning 0, as if
     it reached end of input *)

procedure yyabort;
  (* like yyaccept, but causes parser to return with value 1, as if an
     unrecoverable syntax error had been encountered *)

procedure yyerrlab;
  (* causes error recovery to be started, as if a syntax error had been
     encountered *)

procedure yyerrok;
  (* when in error mode, resets the parser to its normal mode of
     operation *)

(* Flags used internally by the parser routine: *)

var

yyflag    : ( yyfnone, yyfaccept, yyfabort, yyferror );
yyerrflag : Integer;

implementation

uses uLog;

procedure yyerror ( msg : String );
  begin
    //log.add('','YaccLib:yyerror',msg,vError);
    log.add('','yyerror',msg,vError);
  end(*yyerrmsg*);

procedure yyclearin;
  begin
    yychar := -1;
  end(*yyclearin*);

procedure yyaccept;
  begin
    yyflag := yyfaccept;
  end(*yyaccept*);

procedure yyabort;
  begin
    yyflag := yyfabort;
  end(*yyabort*);

procedure yyerrlab;
  begin
    yyflag := yyferror;
  end(*yyerrlab*);

procedure yyerrok;
  begin
    yyerrflag := 0;
  end(*yyerrork*);

end(*YaccLib*).
