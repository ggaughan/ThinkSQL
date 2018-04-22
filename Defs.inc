//{$DEFINE NO_GARBAGE_COLLECTOR}    //debug
                                    //Note: Garbage Collect Catalog is still available anyway!

{$IFDEF WIN32}
  {.$DEFINE USE_APPLICATION} //Windows application.processMessages to prevent other apps. hanging (also in DPR)
  {$IFNDEF USE_APPLICATION}
    {$DEFINE USE_PROCESS_MESSAGES} //Non-Forms Windows message handler
  {$ENDIF}
{$ENDIF}

{.$DEFINE DEBUG_LOG} //must turn off!
{$IFDEF DEBUG_LOG}
  {$DEFINE LOG}
{.$DEFINE FLUSH_AFTER_EVERY_LOG} //must turn off!
{$ENDIF}
{$IFDEF FPC}
  {$Define D2007up}
  {$Define D2006up}
  {$Define D7up}
  {$Define D6up}
{$ELSE}
  {$IF CompilerVersion = 18.5}
  {$Define D2007}
  {$IFEnd}

  {$IF CompilerVersion >= 18.5}
  {$Define D2007up}
  {$Define D2006up}
  {$Define D7up}
  {$Define D6up}
  {$IFEnd}
{$ENDIF}

