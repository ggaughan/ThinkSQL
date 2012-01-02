package uk.co.thinksql;

/*       ThinkSQL Relational Database Management System
              Copyright © 2000-2012  Greg Gaughan
                  See LICENCE.txt for details
*/

import java.io.*;
import uk.co.thinksql.Global.*;

public class GlobalUtil
{

  public static void logError(String s) {
    if (Global.debug) {System.out.println(s);} //else keep silent i.e. when live
  }
  


}
