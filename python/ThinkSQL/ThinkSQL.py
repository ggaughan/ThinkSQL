'''A Pure Python DB-API 2.0 compliant interface to ThinkSQL.

            Copyright © 2000-2012  Greg Gaughan

   http://www.thinksql.co.uk
'''

from string import split,replace
import struct
import cStringIO
import warnings
import socket
import datetime

try:
    from fixedpoint import FixedPoint
    have_fixedpoint = True
except ImportError:
    have_fixedpoint = False

apilevel='2.0'

threadsafety=1

paramstyle='qmark'

__copyright__ = "(c)Copyright 2000-2012 Greg Gaughan"
__author__ = "Greg Gaughan"

def connect(dsn=None, user=None, password=None, host=None,
            database=None, port=None):
    '''Create and open a connection.

       connect(dsn=None, user='DEFAULT', password='', host='localhost',
               database='', port=9075)

       Returns a connection object.
    '''

    #Defaults
    _d = {'host':'localhost','port':9075, 'database':'',
          'user':'DEFAULT', 'password':''}

    #todo Parse any DSN

    #Now use any keywords
    if (user is not None): _d['user'] = user
    if (password is not None): _d['password'] = password
    if (host is not None): _d['host'] = host
    try:
        params = split(host,':')
        _d['host'] = params[0]
        _d['port'] = params[1]
    except:
        pass
    if (database is not None): _d['database']=database
    if (port is not None):_d['port'] = port

    return connection(_d['host'], _d['port'], _d['database'],
                      _d['user'], _d['password'])

#Connection class -------------------------------------------------------------
class connection:
    def __init__(self, host=None, port=None, catalog=None,
                 user=None, password=None):
        self.state=_stateClosed

        self.marshalBuffer=marshalBuffer(host, port)

        self._Server=''
        self._Catalog=catalog
        self._Username=user
        self._Password=password

        self._Autocommit=False #Python has it right, unlike ODBC, JDBC etc!

        self.resultErrCode=None
        self.resultErrText=''

        if self.marshalBuffer.sendHandshake()!=_ok: #send raw handshake
            raise HandshakeError, str(_seHandshakeFailed)+' '+_seHandshakeFailedText

        #Now the server knows we're using CLI protocol we can use the marshal buffer
        self.marshalBuffer.putSQLUSMALLINT(_clientCLIversion) #special version marker for initial protocol handshake
        if _clientCLIversion>=93:
            self.marshalBuffer.putSQLUSMALLINT(_CLI_PYTHON_DBAPI)

        if self.marshalBuffer.send()!=_ok:
            raise HandshakeError, str(_seHandshakeFailed)+' '+_seHandshakeFailedText

        #Wait for handshake response
        if self.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        functionId=self.marshalBuffer.getFunction()
        if functionId!=_SQL_API_handshake:
            raise HandshakeError, str(_seHandshakeFailed)+' '+_seHandshakeFailedText

        self.serverCLIversion=self.marshalBuffer.getSQLUSMALLINT() #note server's protocol
        if self.serverCLIversion>=93:
            self.serverTransactionKey=self.marshalBuffer.getSQLPOINTER() #note server's transaction key

        #Now SQLconnect
        self.marshalBuffer.clearToSend()

        self.marshalBuffer.putFunction(_SQL_API_SQLCONNECT)
        self.marshalBuffer.putSQLHDBC(0) #(int)(self)
        if self._Catalog=='':
            self.marshalBuffer.putpUCHAR_SWORD(self._Server)
        else:
            self.marshalBuffer.putpUCHAR_SWORD(self._Server+'.'+self._Catalog)
        self.marshalBuffer.putpUCHAR_SWORD(self._Username)
        self.marshalBuffer.putpUCHAR_SWORD(self._Password) #todo encrypt
        if self.marshalBuffer.send()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        #Wait for read to return the response
        if self.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        functionId=self.marshalBuffer.getFunction()
        if functionId!=_SQL_API_SQLCONNECT:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        self.resultCode=self.marshalBuffer.getRETCODE()

        #if error, then get error details: local-number, default-text
        self.errCount=self.marshalBuffer.getSQLINTEGER() #error count
        if self.resultCode==_SQL_ERROR:
            for err in range(self.errCount):
                self.resultErrCode=self.marshalBuffer.getSQLINTEGER()
                self.resultErrText=self.marshalBuffer.getpUCHAR_SWORD()
            raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText

        #Ok, we're connected
        self.state=_stateOpen

    def cursor(self):
        '''Create a new cursor on the connection.
        '''
        if self.state!=_stateOpen:
            raise InterfaceError, str(_seConnectionNotOpen)+' '+_seConnectionNotOpenText

        return cursor(self)

    def close(self):
        '''Close the connection.
        '''
        #Negotiate disconnection
        if self.state!=_stateOpen:
            raise InterfaceError, str(_seConnectionNotOpen)+' '+_seConnectionNotOpenText

        self.marshalBuffer.clearToSend()
        self.marshalBuffer.putFunction(_SQL_API_SQLDISCONNECT)
        self.marshalBuffer.putSQLHDBC(0) #(int)(self)
        if self.marshalBuffer.send()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        #Wait for read to return the response
        if self.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        functionId=self.marshalBuffer.getFunction()
        if functionId!=_SQL_API_SQLDISCONNECT:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        self.resultCode=self.marshalBuffer.getRETCODE()

        #if error, then get error details: local-number, default-text
        self.errCount=self.marshalBuffer.getSQLINTEGER() #error count
        if self.resultCode==_SQL_ERROR:
            for err in range(self.errCount):
                self.resultErrCode=self.marshalBuffer.getSQLINTEGER()
                self.resultErrText=self.marshalBuffer.getpUCHAR_SWORD()
            raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText

        #Try to disconnect from the server
        self.marshalBuffer.close() #close this connection
        self.state=_stateClosed

    def commit(self):
        '''Commit the current transaction.
        '''
        #Send SQLendTran to server
        self.marshalBuffer.clearToSend()
        self.marshalBuffer.putFunction(_SQL_API_SQLENDTRAN)
        self.marshalBuffer.putSQLHDBC(0)  #todo pass TranId?
        self.marshalBuffer.putSQLSMALLINT(_SQL_COMMIT)
        if self.marshalBuffer.send()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        #Wait for read to return the response
        if self.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        functionId=self.marshalBuffer.getFunction()
        if functionId!=_SQL_API_SQLENDTRAN:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        self.resultCode=self.marshalBuffer.getRETCODE()

        #if error, then get error details: local-number, default-text
        self.errCount=self.marshalBuffer.getSQLINTEGER() #error count
        if self.resultCode==_SQL_ERROR:
            for err in range(self.errCount):
                self.resultErrCode=self.marshalBuffer.getSQLINTEGER()
                self.resultErrText=self.marshalBuffer.getpUCHAR_SWORD()
            raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText


    def rollback(self):
        '''Rollback the current transaction.
        '''
        #Send SQLendTran to server
        self.marshalBuffer.clearToSend()
        self.marshalBuffer.putFunction(_SQL_API_SQLENDTRAN)
        self.marshalBuffer.putSQLHDBC(0)  #todo pass TranId?
        self.marshalBuffer.putSQLSMALLINT(_SQL_ROLLBACK)
        if self.marshalBuffer.send()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        #Wait for read to return the response
        if self.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        functionId=self.marshalBuffer.getFunction()
        if functionId!=_SQL_API_SQLENDTRAN:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        self.resultCode=self.marshalBuffer.getRETCODE()

        #if error, then get error details: local-number, default-text
        self.errCount=self.marshalBuffer.getSQLINTEGER() #error count
        if self.resultCode==_SQL_ERROR:
            for err in range(self.errCount):
              self.resultErrCode=self.marshalBuffer.getSQLINTEGER()
              self.resultErrText=self.marshalBuffer.getpUCHAR_SWORD()
            raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText


    def __del__(self):
        if self.state==_stateOpen:
            self.close()

#Cursor class -----------------------------------------------------------------
class cursor(object):
    def __init__(self, conn):
        '''Open a new cursor (statement) on the specified connection.
        '''
        self._Con=conn

        self.colCount=None
        self.col=[]
        self.paramCount=None
        self.param=[]

        self.serverStatementHandle=-1 #=> not connected
        self.resultSet=False
        self.prepared=False
        self._affectedRowCount=None
        self.lastSQL=None
        self.lastArraySize=1 #server default

        self._description=None

        self.resultErrCode=None
        self.resultErrText=''

        #We notify the server of this new command(=stmt)
        self._Con.marshalBuffer.clearToSend()
        self._Con.marshalBuffer.putFunction(_SQL_API_SQLALLOCHANDLE)
        self._Con.marshalBuffer.putSQLSMALLINT(_SQL_HANDLE_STMT)
        self._Con.marshalBuffer.putSQLHDBC(0)  #todo _Con
        if self._Con.marshalBuffer.send()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        #Wait for response
        if self._Con.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        functionId=self._Con.marshalBuffer.getFunction()
        if functionId!=_SQL_API_SQLALLOCHANDLE:
           raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        serverS=self._Con.marshalBuffer.getSQLHSTMT() #server will return 0 if failed

        self.resultCode=self._Con.marshalBuffer.getRETCODE()

        #if error, then get error details: local-number, default-text
        self.errCount=self._Con.marshalBuffer.getSQLINTEGER() #error count
        if self.resultCode==_SQL_ERROR:
            for err in range(self.errCount):
                self.resultErrCode=self._Con.marshalBuffer.getSQLINTEGER()
                self.resultErrText=self._Con.marshalBuffer.getpUCHAR_SWORD()
            raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText

        self.serverStatementHandle=serverS  #we will pass this reference to server in future calls

    def close(self):
        '''Close the cursor.
        '''
        if self.serverStatementHandle<=0:
            pass
        else:
            self._resultSetClose()  #close the server cursor, if any

            #Free the server handle
            self._Con.marshalBuffer.clearToSend()
            self._Con.marshalBuffer.putFunction(_SQL_API_SQLFREEHANDLE)
            self._Con.marshalBuffer.putSQLSMALLINT(_SQL_HANDLE_STMT)
            self._Con.marshalBuffer.putSQLHSTMT(self.serverStatementHandle)  #pass server statement ref
            if self._Con.marshalBuffer.send()!=_ok:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

            #Wait for response
            if self._Con.marshalBuffer.read()!=_ok:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
            functionId=self._Con.marshalBuffer.getFunction()
            if functionId!=_SQL_API_SQLFREEHANDLE:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

            self.resultCode=self._Con.marshalBuffer.getRETCODE()

            #if error, then get error details: local-number, default-text
            self.errCount=self._Con.marshalBuffer.getSQLINTEGER() #error count
            if self.resultCode==_SQL_ERROR:
                for err in range(self.errCount):
                    self.resultErrCode=self._Con.marshalBuffer.getSQLINTEGER()
                    self.resultErrText=self._Con.marshalBuffer.getpUCHAR_SWORD()
                raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText

            self.serverStatementHandle=-1 #not connected

    def _resultSetClose(self):
        if self.resultSet:
            self._Con.marshalBuffer.clearToSend()
            self._Con.marshalBuffer.putFunction(_SQL_API_SQLCLOSECURSOR)
            self._Con.marshalBuffer.putSQLHSTMT(self.serverStatementHandle) #pass server statement ref
            if self.prepared:
                self._Con.marshalBuffer.putSQLSMALLINT(0) #keep server plan
            else:
                self._Con.marshalBuffer.putSQLSMALLINT(1) #remove server plan
            if self._Con.marshalBuffer.send()!=_ok:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

            #Wait for response
            if self._Con.marshalBuffer.read()!=_ok:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
            functionId=self._Con.marshalBuffer.getFunction()
            if functionId!=_SQL_API_SQLCLOSECURSOR:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

            self.resultCode=self._Con.marshalBuffer.getRETCODE()

            #if error, then get error details: local-number, default-text
            self.errCount=self._Con.marshalBuffer.getSQLINTEGER() #error count
            if self.resultCode==_SQL_ERROR:
                for err in range(self.errCount):
                    self.resultErrCode=self._Con.marshalBuffer.getSQLINTEGER()
                    self.resultErrText=self._Con.marshalBuffer.getpUCHAR_SWORD()
                raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText


    def _doPrepare(self,sql):
        self.lastSQL=sql

        #call server prepare
        self._Con.marshalBuffer.clearToSend()
        self._Con.marshalBuffer.putFunction(_SQL_API_SQLPREPARE)
        self._Con.marshalBuffer.putSQLHSTMT(self.serverStatementHandle)
        self._Con.marshalBuffer.putpUCHAR_SDWORD(sql)
        if self._Con.marshalBuffer.send()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        #Wait for response
        if self._Con.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        functionId=self._Con.marshalBuffer.getFunction()
        if functionId!=_SQL_API_SQLPREPARE:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        self.resultCode=self._Con.marshalBuffer.getRETCODE()

        #if error, then get error details: local-number, default-text
        self.errCount=self._Con.marshalBuffer.getSQLINTEGER() #error count
        if self.resultCode==_SQL_ERROR:
            for err in range(self.errCount):
                self.resultErrCode=self._Con.marshalBuffer.getSQLINTEGER()
                self.resultErrText=self._Con.marshalBuffer.getpUCHAR_SWORD()
            #raise later...

        resSet=self._Con.marshalBuffer.getSQLUSMALLINT()
        #Remember this for future state changes
        if resSet==_SQL_TRUE:
            self.resultSet=True
        else:
            self.resultSet=False

        if self.resultCode==_SQL_ERROR:
            raise ProgrammingError, str(self.resultErrCode)+' '+self.resultErrText

        if self.resultSet:
            #Now get the cursor column count & definitions
            self.col=[]
            self.colCount=self._Con.marshalBuffer.getSQLINTEGER()
            for i in range(self.colCount):
                rn=self._Con.marshalBuffer.getSQLSMALLINT()
                self.newcol=_columnSQL()
                self.newcol.iFldNum=rn
                self.newcol.colName=self._Con.marshalBuffer.getpSQLCHAR_SWORD()[:-1]  #remove trailing \0

                self.newcol.iFldType=self._Con.marshalBuffer.getSQLSMALLINT()

                if self._Con.serverCLIversion>=93:
                    self.newcol.iUnits1=self._Con.marshalBuffer.getSQLINTEGER()
                else:
                    self.newcol.iUnits1=self._Con.marshalBuffer.getSQLSMALLINT()

                self.newcol.iUnits2=self._Con.marshalBuffer.getSQLSMALLINT()
                self.newcol.iNullOffset=self._Con.marshalBuffer.getSQLSMALLINT()

                self.col.append(self.newcol)

            #Now set the description
            self._description=[]
            for newcol in self.col:
                if newcol.iFldType==_SQL_NUMERIC or newcol.iFldType==_SQL_DECIMAL:
                    dsize=newcol.iUnits1+newcol.iUnits2+1
                    isize=newcol.iUnits1+newcol.iUnits2
                elif newcol.iFldType==_SQL_SMALLINT:
                    dsize=5
                    isize=2
                elif newcol.iFldType==_SQL_INTEGER:
                    dsize=10
                    isize=4
                elif newcol.iFldType==_SQL_REAL:
                    dsize=7
                    isize=4
                elif newcol.iFldType==_SQL_FLOAT or newcol.iFldType==_SQL_DOUBLE:
                    dsize=15
                    isize=8
                elif newcol.iFldType==_SQL_TYPE_DATE:
                    dsize=10
                    isize=4
                elif newcol.iFldType==_SQL_TYPE_TIME:
                    dsize=8
                    if newcol.iUnits2>0:
                        dsize=9+newcol.iUnits2
                    isize=8
                elif newcol.iFldType==_SQL_TYPE_TIMESTAMP:
                    dsize=19
                    if newcol.iUnits2>0:
                        dsize=20+newcol.iUnits2
                    isize=12
                else:
                    dsize=newcol.iUnits1
                    isize=newcol.iUnits1

                self._description.append((newcol.colName, newcol.iFldType,
                                          dsize, isize, newcol.iUnits1, newcol.iUnits2, None))
        else:
            #no result set
            self._description=None
            self.colCount=0

        #Now get the param count & definitions
        self.paramCount=self._Con.marshalBuffer.getSQLINTEGER()
        for i in range(self.paramCount):
            rn=self._Con.marshalBuffer.getSQLSMALLINT()
            self.newparam=_paramSQL()
            self.newparam.iParamNum=rn
            self.newparam.colName=self._Con.marshalBuffer.getpSQLCHAR_SWORD()

            self.newparam.iDataType=self._Con.marshalBuffer.getSQLSMALLINT()

            self.newparam.iArgType=_ptInput #default

            if self._Con.serverCLIversion>=93:
                self.newparam.iUnits1=self._Con.marshalBuffer.getSQLINTEGER()
            else:
                self.newparam.iUnits1=self._Con.marshalBuffer.getSQLSMALLINT()
            self.newparam.iUnits2=self._Con.marshalBuffer.getSQLSMALLINT()
            x=self._Con.marshalBuffer.getSQLSMALLINT()

            self.param.append(self.newparam)


        #Now auto-bind all the columns
        for i in range(self.colCount):
            self._Con.marshalBuffer.clearToSend()
            self._Con.marshalBuffer.putFunction(_SQL_API_SQLSETDESCFIELD)
            self._Con.marshalBuffer.putSQLHSTMT(self.serverStatementHandle) #pass server statement ref

            self._Con.marshalBuffer.putSQLSMALLINT(_SQL_ATTR_APP_ROW_DESC)
            self._Con.marshalBuffer.putSQLSMALLINT(i+1) #=colRef(-1) on the server
            self._Con.marshalBuffer.putSQLSMALLINT(_SQL_DESC_DATA_POINTER)
            self._Con.marshalBuffer.putSQLPOINTER(1) #= 0=unbound, else bound
            self._Con.marshalBuffer.putSQLINTEGER(0)

            if self._Con.marshalBuffer.send()!=_ok:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

            #Wait for response
            if self._Con.marshalBuffer.read()!=_ok:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
            functionId=self._Con.marshalBuffer.getFunction()
            if functionId!=_SQL_API_SQLSETDESCFIELD:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

            self.resultCode=self._Con.marshalBuffer.getRETCODE()

            #if error, then get error details: local-number, default-text
            self.errCount=self._Con.marshalBuffer.getSQLINTEGER() #error count
            if self.resultCode==_SQL_ERROR:
                for err in range(self.errCount):
                    self.resultErrCode=self._Con.marshalBuffer.getSQLINTEGER()
                    self.resultErrText=self._Con.marshalBuffer.getpUCHAR_SWORD()
                #raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText

    def _doExecute(self, parameters):
        self._Con.marshalBuffer.clearToSend()
        self._Con.marshalBuffer.putFunction(_SQL_API_SQLEXECUTE)
        self._Con.marshalBuffer.putSQLHSTMT(self.serverStatementHandle) #pass server statement ref

        #Write row count
        self._Con.marshalBuffer.putSQLUINTEGER(1)

        for row in range(1,2):
            #Now send the param count & data for this row
            if parameters is None:
                self._Con.marshalBuffer.putSQLINTEGER(0)
            else:
                self._Con.marshalBuffer.putSQLINTEGER(len(parameters))

                for i in range(len(parameters)):
                    self._Con.marshalBuffer.putSQLSMALLINT((i+1))

                    #Put the data
                    #Put the null flag
                    tempNull=_SQL_FALSE #default
                    if parameters[i] is None:
                        tempNull=_SQL_TRUE
                    self._Con.marshalBuffer.putSQLSMALLINT(tempNull)

                    #Note: we only send length+data if not null
                    if tempNull==_SQL_FALSE:
                        if isinstance(parameters[i],BinaryString):
                            self._Con.marshalBuffer.putpDataSDWORD(str(parameters[i])) #omit \0 if BLOB
                        else  :
                            self._Con.marshalBuffer.putpDataSDWORD(str(parameters[i])+chr(0))

        if self._Con.marshalBuffer.send()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        #Wait for response
        if self._Con.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        functionId=self._Con.marshalBuffer.getFunction()
        if functionId!=_SQL_API_SQLEXECUTE:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        self.resultCode=self._Con.marshalBuffer.getRETCODE()

        #if error, then get error details: local-number, default-text
        self.errCount=self._Con.marshalBuffer.getSQLINTEGER() #error count
        if self.resultCode==_SQL_ERROR:
            for err in range(self.errCount):
                self.resultErrCode=self._Con.marshalBuffer.getSQLINTEGER()
                self.resultErrText=self._Con.marshalBuffer.getpUCHAR_SWORD()
            raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText

        #Get the row count - only valid for insert/update/delete
        self._affectedRowCount=self._Con.marshalBuffer.getSQLINTEGER()

        if self._Con.serverCLIversion>=92:
            #Now get any late (post-prepare) resultSet definition, i.e. for stored procedure return cursors
            #False here doesn't mean we have no result set, it means we should use the details from SQLprepare
            lateResSet=self._Con.marshalBuffer.getSQLUSMALLINT()
            #Remember this for future state changes
            if lateResSet==_SQL_TRUE:
                self.resultSet=True
            #else leave resultSet as was

            if lateResSet==_SQL_TRUE:
                #Now get the cursor column count & definitions
                self.col=[]
                self.colCount=self._Con.marshalBuffer.getSQLINTEGER()
                for i in range(self.colCount):
                    rn=self._Con.marshalBuffer.getSQLSMALLINT()
                    self.newcol=_columnSQL()
                    self.newcol.iFldNum=rn
                    self.newcol.colName=self._Con.marshalBuffer.getpSQLCHAR_SWORD()[:-1]  #remove trailing \0

                    self.newcol.iFldType=self._Con.marshalBuffer.getSQLSMALLINT()

                    if self._Con.serverCLIversion>=93:
                      self.newcol.iUnits1=self._Con.marshalBuffer.getSQLINTEGER()
                    else:
                      self.newcol.iUnits1=self._Con.marshalBuffer.getSQLSMALLINT()

                    self.newcol.iUnits2=self._Con.marshalBuffer.getSQLSMALLINT()
                    self.newcol.iNullOffset=self._Con.marshalBuffer.getSQLSMALLINT()

                    self.col.append(self.newcol)

                #Now set the description
                self._description=[]
                for rn,newcol in self.col:
                    if newcol.iFldType==_SQL_NUMERIC or newcol.iFldType==_SQL_DECIMAL:
                        dsize=newcol.iUnits1+newcol.iUnits2+1
                        isize=newcol.iUnits1+newcol.iUnits2
                    elif newcol.iFldType==_SQL_SMALLINT:
                        dsize=5
                        isize=2
                    elif newcol.iFldType==_SQL_INTEGER:
                        dsize=10
                        isize=4
                    elif newcol.iFldType==_SQL_REAL:
                        dsize=7
                        isize=4
                    elif newcol.iFldType==_SQL_FLOAT or newcol.iFldType==_SQL_DOUBLE:
                        dsize=15
                        isize=8
                    elif newcol.iFldType==_SQL_TYPE_DATE:
                        dsize=10
                        isize=4
                    elif newcol.iFldType==_SQL_TYPE_TIME:
                        dsize=8
                        if newcol.iUnits2>0:
                            dsize=9+newcol.iUnits2
                        isize=8
                    elif newcol.iFldType==_SQL_TYPE_TIMESTAMP:
                        dsize=19
                        if newcol.iUnits2>0:
                            dsize=20+newcol.iUnits2
                        isize=12
                    else:
                        dsize=newcol.iUnits1
                        isize=newcol.iUnits1

                    self._description.append((newcol.colName, newcol.iFldType,
                                            dsize, isize, newcol.iUnits1, newcol.iUnits2, None))
            #else no late result set: leave as was (i.e. don't zeroise self.description)
        #else young server cannot handle this

        if self.resultCode==_SQL_SUCCESS or self.resultCode==_SQL_SUCCESS_WITH_INFO:
            #we SQLendTran now if in autocommit mode & if not select/result-set
            if not self.resultSet and self._Con._Autocommit:
                self._Con.commit()
        elif self.resultCode==_SQL_NEED_DATA:
            if self.prepared:
                rn=self._Con.marshalBuffer.getSQLSMALLINT() #this is the parameter id that's missing
                raise InterfaceError, str(_seMissingParameter)+' '+_seMissingParameterText


    def execute(self, operation=None, parameters=None):
        '''Execute the specified SQL operation, possibly opening a result set.
        '''
        self._doPrepare(operation)
        self._doExecute(parameters)
        return None

    def executemany(self, operation=None, seq_of_parameters=None):
        '''Repeatedly execute the specified SQL operation, once for each set of
           parameters in the sequence.

           This is more efficient than repeatedly calling the execute method.
        '''
        self._doPrepare(operation)
        self.prepared=True
        for parameters in seq_of_parameters:
            if self.resultSet: #close any existing query result set on this cursor before we re-execute
                self._resultSetClose()
            last=self._doExecute(parameters)
        return last


    def callproc(self, procname, parameters=None):
        '''Call the specified stored procedure with the parameters.

           May return a result set accessible using the fetchXXX methods.
        '''
        return self.execute('CALL '+procname+replace(replace(str(parameters),'[','('),']',')'))


    def _setArraySize(self, arraySize=1):
        '''Tell the server how many rows to return per fetch.
        '''
        self._Con.marshalBuffer.clearToSend()
        self._Con.marshalBuffer.putFunction(_SQL_API_SQLSETDESCFIELD)
        self._Con.marshalBuffer.putSQLHSTMT(self.serverStatementHandle)
        self._Con.marshalBuffer.putSQLSMALLINT(_SQL_ATTR_APP_ROW_DESC)
        self._Con.marshalBuffer.putSQLSMALLINT(0)
        self._Con.marshalBuffer.putSQLSMALLINT(_SQL_DESC_ARRAY_SIZE)
        self._Con.marshalBuffer.putSQLUINTEGER(arraySize)
        self._Con.marshalBuffer.putSQLINTEGER(0) #bufferLength = n/a here
        if self._Con.marshalBuffer.send()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        #Wait for response
        if self._Con.marshalBuffer.read()!=_ok:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
        functionId=self._Con.marshalBuffer.getFunction()
        if functionId!=_SQL_API_SQLSETDESCFIELD:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        self.resultCode=self._Con.marshalBuffer.getRETCODE()

        #if error, then get error details: local-number, default-text
        self.errCount=self._Con.marshalBuffer.getSQLINTEGER() #error count
        if self.resultCode==_SQL_ERROR:
            for err in range(self.errCount):
                self.resultErrCode=self._Con.marshalBuffer.getSQLINTEGER()
                self.resultErrText=self._Con.marshalBuffer.getpUCHAR_SWORD()
            raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText

        #record the latest value
        self.lastArraySize=arraySize


    def _fetch(self, arraySize=None):
        if self.resultSet:
            res=[]

            if arraySize!=None and arraySize!=self.lastArraySize:
                self._setArraySize(arraySize)

            #call server fetchScroll
            self._Con.marshalBuffer.clearToSend()
            self._Con.marshalBuffer.putFunction(_SQL_API_SQLFETCHSCROLL)
            self._Con.marshalBuffer.putSQLHSTMT(self.serverStatementHandle)
            self._Con.marshalBuffer.putSQLSMALLINT(_SQL_FETCH_NEXT)
            self._Con.marshalBuffer.putSQLINTEGER(0)
            if self._Con.marshalBuffer.send()!=_ok:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

            #Wait for response
            if self._Con.marshalBuffer.read()!=_ok:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText
            functionId=self._Con.marshalBuffer.getFunction()
            if functionId!=_SQL_API_SQLFETCHSCROLL:
                raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

            #resultCode comes later: first we retrieve any result data

            #Read row count
            rowCount=self._Con.marshalBuffer.getSQLUINTEGER()

            for row in range(rowCount):
                rowres=[]
                #Now get the col count & data for this row
                self.colCount=self._Con.marshalBuffer.getSQLINTEGER()
                for i in range(self.colCount):
                    rn=self._Con.marshalBuffer.getSQLSMALLINT()

                    if rn<=self.colCount:
                        #Get the null flag
                        tempNull=self._Con.marshalBuffer.getSQLSMALLINT()
                        if tempNull==_SQL_TRUE:
                            rowres.append(None)
                        else:
                            #Note: we only get length+data if not null
                            self.col[i].data=self._Con.marshalBuffer.getpDataSDWORD()
                            #Convert the raw data to Python data
                            if self.col[i].iFldType==_SQL_CHAR or self.col[i].iFldType==_SQL_VARCHAR:
                                rowres.append(self.col[i].data)
                            elif self.col[i].iFldType==_SQL_NUMERIC or self.col[i].iFldType==_SQL_DECIMAL:
                                if have_fixedpoint:
                                    fp=str(struct.unpack('<q',self.col[i].data)[0])
                                    fp=fp[:len(fp)-self.col[i].iUnits2]+'.'+fp[len(fp)-self.col[i].iUnits2:]
                                    rowres.append(FixedPoint(fp,self.col[i].iUnits2))
                                else:                                    
                                    rowres.append((struct.unpack('<q',self.col[i].data)[0]) / float(10**self.col[i].iUnits2)) #i.e. shift scale decimal places to the right
                            elif self.col[i].iFldType==_SQL_INTEGER:
                                rowres.append(struct.unpack('<i',self.col[i].data)[0])
                            elif self.col[i].iFldType==_SQL_SMALLINT:
                                rowres.append(struct.unpack('<h',self.col[i].data)[0])
                            elif self.col[i].iFldType==_SQL_FLOAT or self.col[i].iFldType==_SQL_REAL or self.col[i].iFldType==_SQL_DOUBLE:
                                rowres.append(struct.unpack('<d',self.col[i].data)[0])
                            elif self.col[i].iFldType==_SQL_TYPE_DATE:
                                p=struct.unpack(_sqlDate,self.col[i].data)
                                rowres.append(datetime.date(p[0],p[1],p[2]))
                            elif self.col[i].iFldType==_SQL_TYPE_TIME:
                                p=struct.unpack(_sqlTime,self.col[i].data)
                                rowres.append(datetime.time(p[0],p[1],int(p[2] / float(10**_TIME_MAX_SCALE)))) #todo Adjust the scale? p[3]
                            elif self.col[i].iFldType==_SQL_TYPE_TIMESTAMP:
                                p=struct.unpack(_sqlTimestamp,self.col[i].data)
                                rowres.append(datetime.datetime(p[0],p[1],p[2],p[3],p[4],int(p[5] / float(10**_TIME_MAX_SCALE)))) #todo Adjust the scale? p[6]
                            elif self.col[i].iFldType==_SQL_LONGVARCHAR or self.col[i].iFldType==_SQL_LONGVARBINARY:
                                rowres.append(self.col[i].data)
                            #todo SQL_INTERVAL etc.
                            else:
                                rowres.append('?') #todo use raw data or None instead?
                    else:
                        raise OperationalError, str(_seInvalidColumnIndex)+' '+_seInvalidColumnIndexText

                #get row status
                sqlRowStatus=self._Con.marshalBuffer.getSQLUSMALLINT()

                if sqlRowStatus==_SQL_ROW_NOROW:
                    break #-> no more data

                if arraySize>1:
                    res.append(tuple(rowres))
                else:
                    res=tuple(rowres)

            self.resultCode=self._Con.marshalBuffer.getRETCODE()

            if self.resultCode==_SQL_NO_DATA and arraySize==1:
                res=None  #-> no more data

            #if error, then get error details: local-number, default-text
            self.errCount=self._Con.marshalBuffer.getSQLINTEGER() #error count
            if self.resultCode==_SQL_ERROR:
                for err in range(self.errCount):
                    self.resultErrCode=self._Con.marshalBuffer.getSQLINTEGER()
                    self.resultErrText=self._Con.marshalBuffer.getpUCHAR_SWORD()
                raise DatabaseError, str(self.resultErrCode)+' '+self.resultErrText

            return res
        else:
            raise InterfaceError, str(_seResultSetNotOpen)+' '+_seResultSetNotOpenText

    def fetchone(self):
        '''Fetch the next row from the cursor's result set.
        '''
        return self._fetch(1)

    def fetchmany(self, size=None):
        '''Fetch a number of rows from the cursor's result set.
        '''
        if size is None:
            size=self.lastArraySize

        return self._fetch(size)

    def fetchall(self):
        '''Fetch all the remaining rows from the cursor's result set.
        '''
        res=[]
        while 1:
            r=self.fetchone()
            if r is None:
                break
            res.append(r)

        return res

    def _getaffectedRowCount(self):
        return self._affectedRowCount

    rowcount=property(_getaffectedRowCount, doc='Number of affected row(s)')

    def _getdescription(self):
        return self._description

    def _getconnection(self):
        warnings.warn('DB-API extension cursor.connection used')
        return self._Con

    description=property(_getdescription, doc='Column description(s)')

    def _getarraysize(self):
        return self.lastArraySize

    arraysize=property(_getarraysize, _setArraySize, doc='Number of rows to fetch with fetchmany()')

    def __iter__(self):
        return self

    def next(self):
        x=self.fetchone()
        if x is None:
            raise StopIteration
        return x

    def __del__(self):
        self.close()

#Column/Parameter classes -----------------------------------------------------
class _columnSQL:
    def __init__(self):
        self.iFldNum=None
        self.iFldType=None
        self.iUnits1=None
        self.iUnits2=None
        self.iNullOffset=None

        self.colName=None
        self.data=None

class _paramSQL:
    def __init__(self):
        self.iParamNum=None
        self.colName=None
        self.iDataType=None
        self.iArgType=None
        self.iUnits1=None
        self.iUnits2=None

        self.buffer=None
        self.bufferLen=None
        self.isNull=None

_clientCLIversion  =100  #client parameter passing version

_CLI_ODBC=1
_CLI_JDBC=2
_CLI_DBEXPRESS=3
_CLI_ADO_NET=4
_CLI_PYTHON_DBAPI=5

_DriverName='ThinkSQL'
_DriverVersion='1.03.01'
__version__ = 1, 03, 01
_DriverMajorVersion=1
_DriverMinorVersion=03

_ok=0
_fail=-1
_failString=''

_stateClosed=0
_stateOpen=1

_sizeof_short=2
_sizeof_int=4
_sizeof_long=8
_sizeof_float=4
_sizeof_double=8
_sizeof_byte=8 #in bits

_sizeof_date=4
_sizeof_dateY=2
_sizeof_dateM=1
_sizeof_dateD=1

_sizeof_time=7
_sizeof_timeH=1
_sizeof_timeM=1
_sizeof_timeS=4
_sizeof_timeSc=1

_TIME_MAX_SCALE=6


_MAX_COL_PER_TABLE=300
_MAX_PARAM_PER_QUERY=300

_SQL_FALSE                                   =0
_SQL_TRUE                                    =1

#parameter types
_ptInput = 0
_ptOutput = 1

_EscapeChar='\\'

_SQL_ERROR=-1
_SQL_ERROR2=_SQL_ERROR
_SQL_SUCCESS=0
_SQL_SUCCESS_WITH_INFO=1
_SQL_STILL_EXECUTING=2
_SQL_NEED_DATA=99
_SQL_NO_DATA=100


_SQL_CHAR                                    =1
_SQL_NUMERIC                                 =2
_SQL_DECIMAL                                 =3
_SQL_INTEGER                                 =4
_SQL_SMALLINT                                =5
_SQL_FLOAT                                   =6
_SQL_REAL                                    =7
_SQL_DOUBLE                                  =8
_SQL_DATETIME                                =9
_SQL_INTERVAL                               =10
_SQL_VARCHAR                                =12

_SQL_TYPE_DATE                              =91
_SQL_TYPE_TIME                              =92
_SQL_TYPE_TIMESTAMP                         =93

_SQL_LONGVARCHAR                            =-1
#SQL_BINARY         =-2
#SQL_VARBINARY      =-3
_SQL_LONGVARBINARY                          =-4
#future use:  SQL_BIGINT         =-5


_SQL_API_SQLCONNECT                         =7
_SQL_API_SQLDISCONNECT                      =9
_SQL_API_SQLEXECUTE                         =12
_SQL_API_SQLPREPARE                         =19
_SQL_API_SQLGETDATA                         =43
_SQL_API_SQLGETINFO                         =45

_SQL_API_SQLALLOCHANDLE                     =1001
_SQL_API_SQLCLOSECURSOR                     =1003
_SQL_API_SQLENDTRAN                         =1005
_SQL_API_SQLFREEHANDLE                      =1006
_SQL_API_SQLSETDESCFIELD                    =1017
_SQL_API_SQLFETCHSCROLL                     =1021

_SQL_ATTR_APP_ROW_DESC                      =10010

_SQL_DESC_ARRAY_SIZE                        =20
_SQL_DESC_DATA_POINTER                      =1010

_SQL_ROW_SUCCESS                            =0
_SQL_ROW_NOROW                              =3


_SQL_API_handshake  =9999

_SQL_HANDLE_STMT                            =3

_SQL_ROLLBACK                               =1
_SQL_COMMIT                                 =0

_SQL_FETCH_NEXT                             =1

_SQL_DBMS_NAME                              =17
_SQL_DBMS_VERSION                           =18


#Errors:
_seNotImplementedYet=500
_seNotImplementedYetText='Not implemented yet'
_seHandshakeFailed=1500
_seHandshakeFailedText='Handshake failed'
_seConnectionFailed=1502
_seConnectionFailedText='Communication link failure'

_seInvalidColumnIndex=1600
_seInvalidColumnIndexText='Invalid column index'
_seInvalidConversion=1602
_seInvalidConversionText='Invalid data conversion'
_seInvalidParameterIndex=1604
_seInvalidParameterIndexText='Invalid parameter index'

_seConnectionNotOpen=1700
_seConnectionNotOpenText='Connection not open'
_seResultSetNotOpen=1702
_seResultSetNotOpenText='No result set'
_seMissingParameter=1704
_seMissingParameterText='Not enough parameters passed'

_ss08001='08001'
_ss08S01='08S01'
_ss42000='42000'
_ssHY000='HY000'
_ssHY010='HT010'
_ssHYC00='HYC00'  #optional feature not implemented yet

_ssNA='NA'

_sqlDate='<hbb' #year:smallint; month:shortint; day:shortint

_sqlTimezone='<bbbx' #sign:shortint (-1=negative, +1=positive, 0=no timezone);    hour:shortint;    minute:shortint

_sqlTime='<bbxxibxxx' #    hour:shortint;    minute:shortint;    second:integer; (stored normalised as SSFFFFFF where number of Fs=TIME_MAX_SCALE)    scale:shortint (used when formatting to dictate how many fractional places to display)

_sqlTimestamp='<hbb bbxxibxxx'

_TIME_MAX_SCALE=6

#Python specifics
#Exception classes ------------------------------------------------------------
class Error(StandardError):
    '''Top-level DB API exception.'''

class Warning(StandardError):
    '''Top-level DB API warning.'''


class InterfaceError(Error):
    '''Interface error.'''

class DatabaseError(Error):
    '''Database error.'''

class DataError(DatabaseError):
    '''Data error.'''

class OperationalError(DatabaseError):
    '''Operational error.'''

class IntegrityError(DatabaseError):
    '''Integrity error.'''

class InternalError(DatabaseError):
    '''Internal error.'''

class ProgrammingError(DatabaseError):
    '''Programming error.'''

class NotSupportedError(DatabaseError):
    '''Not supported error.'''

#ThinkSQL specific errors
class HandshakeError(OperationalError):
    '''Handshake error.'''

class ConnectionError(OperationalError):
    '''Connection error.'''

class DBAPITypeObject:
    def __init__(self, name, *values):
        self.name = name
        self.values = values

    def __repr__(self):
        return self.name

    def __cmp__(self, other):
        if other in self.values:
            return 0
        elif other < self.values:
            return 1
        else:
            return -1

#Type mappings
BINARY = DBAPITypeObject('BINARY', _SQL_LONGVARBINARY)

DATETIME = DBAPITypeObject('DATETIME', _SQL_DATETIME, _SQL_INTERVAL,
                                       _SQL_TYPE_DATE, _SQL_TYPE_TIME, _SQL_TYPE_TIMESTAMP
                                       )

NUMBER = DBAPITypeObject('NUMBER', _SQL_NUMERIC, _SQL_DECIMAL, _SQL_INTEGER, _SQL_SMALLINT,
                                   _SQL_FLOAT, _SQL_REAL, _SQL_DOUBLE)

STRING = DBAPITypeObject('STRING', _SQL_CHAR, _SQL_VARCHAR, _SQL_LONGVARCHAR)

from time import localtime

def Date(year, month, day):
    return '%04d/%02d/%02d' % (year, month, day)

def Time(hour, minute, second):
    return '%02d:%02d:%02d' % (hour, minute, second)

def Timestamp(year, month, day, hour, minute, second):
    return Date(year, month, day)+' '+Time(hour, minute, second)

def DateFromTicks(ticks):
    t=localtime(ticks)
    return Date(t[0],t[1],t[2])

def TimeFromTicks(ticks):
    t=localtime(ticks)
    return Time(t[3],t[4],t[5])

def TimestampFromTicks(ticks):
    t=localtime(ticks)
    return Timestamp(t[0],t[1],t[2],t[3],t[4],t[5])

class BinaryString:
    def __init__(self,s):
        self.value=s
    def __str__(self):
        return self.value

def Binary(string):
    return BinaryString(string) #todo encode/make binary


#MarshalBuffer class ----------------------------------------------------------
class marshalBuffer:
    marshalBufSize=16384
    connectionTimeout=30

    def __init__(self, host, port):
        socket.setdefaulttimeout(self.__class__.connectionTimeout)
        self.clientSocket=socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.buffer=cStringIO.StringIO()

        try:
            self.clientSocket.connect((host, port))
        except:
            raise ConnectionError, str(_seConnectionFailed)+' '+_seConnectionFailedText

        self.clearToSend() #initially clear buffer
        self.bufferLen=0
        self.bufferPtr=0

    def __del__(self):
        self.close()

    def clearToSend(self):
        #Clear before send
        self.bufferLen=0
        self.bufferPtr=0
        self.buffer.truncate(0)
        self.buffer.seek(0)
        return _ok


    def clearToReceive(self):
        #Clear before receive
        self.bufferPtr=0
        self.bufferLen=0
        self.buffer.truncate(0)
        self.buffer.seek(0)
        return _ok

    def sendHandshake(self):
        #Send raw handshake
        try:
            s=struct.pack('<h',_SQL_API_handshake)
            self.clientSocket.send(s)
            return _ok
        except:
            return _fail


    def send(self):
        '''Send a response and then clear the buffer.
        '''
        try:
            i=(self.bufferLen+_sizeof_int)
            #todo assert i=buffer size

            s=struct.pack('<i', i)
            self.clientSocket.send(s)

            self.buffer.flush()
            sent=0
            while sent<(i-4):
                sent=sent+self.clientSocket.send(self.buffer.getvalue()[sent:])
        except:
            return _fail

        try:
            self.clearToSend() #clear send buffer, once sent ok

            return _ok
        except:
            return _fail

    def read(self):
        '''Wait for a response (clear buffer before receiving).
        '''
        self.clearToReceive()

        #try:
        s=self.clientSocket.recv(_sizeof_int)
        i=struct.unpack('<i', s)

        dataCount=i[0]

        dataCount=(dataCount-_sizeof_int) #inclusive
        if self.bufferLen+dataCount>self.__class__.marshalBufSize:
            return _fail #overflow

        #Read the block data into the marshal buffer
        while self.buffer.tell()<dataCount:
            self.buffer.write(self.clientSocket.recv(dataCount-self.buffer.tell()))

        self.bufferLen=(self.bufferLen+dataCount)

        self.buffer.seek(0) #reset the get pointer

        return _ok
        #except:
          #  return _fail


    def putSQLUSMALLINT(self, usi):
        if self.bufferLen+_sizeof_short>self.__class__.marshalBufSize:
            if self.send()!=_ok:
                return _fail #buffer overflow

        if (self.bufferLen+_sizeof_short>self.__class__.marshalBufSize):
            return _fail

        s=struct.pack('<H', usi)
        self.buffer.write(s)
        self.bufferLen+=_sizeof_short

        return _ok

    def getSQLUSMALLINT(self):
        if self.bufferPtr+_sizeof_short>self.bufferLen:
            if self.bufferPtr==self.bufferLen:
                self.read()
            else:
                return _fail

        s=self.buffer.read(_sizeof_short)
        self.bufferPtr+=_sizeof_short
        return struct.unpack('<H', s)[0]

    def getSQLSMALLINT(self):
        if self.bufferPtr+_sizeof_short>self.bufferLen:
            if self.bufferPtr==self.bufferLen:
                self.read()
            else:
                return _fail

        s=self.buffer.read(_sizeof_short)
        self.bufferPtr+=_sizeof_short
        return struct.unpack('<h', s)[0]

    def putSQLINTEGER(self, i):
        if self.bufferLen+_sizeof_int>self.__class__.marshalBufSize:
            if self.send()!=_ok:
                return _fail #buffer overflow

        if (self.bufferLen+_sizeof_int>self.__class__.marshalBufSize):
            return _fail

        s=struct.pack('<i', i)
        self.buffer.write(s)
        self.bufferLen+=_sizeof_int

        return _ok

    def getSQLINTEGER(self):
        if self.bufferPtr+_sizeof_int>self.bufferLen:
            if self.bufferPtr==self.bufferLen:
                self.read()
            else:
                return _fail

        s=self.buffer.read(_sizeof_int)
        self.bufferPtr+=_sizeof_int
        return struct.unpack('<i', s)[0]


    def putpUCHAR_SWORD(self,ss):
        if self.bufferLen+_sizeof_short+len(ss)>self.__class__.marshalBufSize:
            if self.send()!=_ok:
                return _fail #buffer overflow

        if (self.bufferLen+_sizeof_short+len(ss)>self.__class__.marshalBufSize):
            return _fail

        s=struct.pack('<h', len(ss))
        self.buffer.write(s)
        self.bufferLen+=_sizeof_short

        self.buffer.write(ss)
        self.bufferLen+=len(ss)

        return _ok

    def getpUCHAR_SWORD(self):
        if self.bufferPtr+_sizeof_short>self.bufferLen:
            if self.bufferPtr==self.bufferLen:
                self.read()
            else:
                return _fail

        s=self.buffer.read(_sizeof_short)
        self.bufferPtr+=_sizeof_short
        si=struct.unpack('<H', s)[0]

        self.bufferPtr+=si
        return self.buffer.read(si)

    def putpUCHAR_SDWORD(self, ss):
        if self.bufferLen+_sizeof_int+len(ss)>self.__class__.marshalBufSize:
            if self.send()!=_ok:
                return _fail #buffer overflow

        if (self.bufferLen+_sizeof_int+len(ss)>self.__class__.marshalBufSize):
            return _fail

        s=struct.pack('<i', len(ss))
        self.buffer.write(s)
        self.bufferLen+=_sizeof_int

        self.buffer.write(ss)
        self.bufferLen+=len(ss)

        return _ok

    def putpDataSDWORD(self, ss):
        if self.bufferLen>0 and self.bufferLen+_sizeof_int+len(ss)>self.__class__.marshalBufSize:
            if self.send()!=_ok:
                return _fail #buffer overflow

        ui=len(ss)
        s=struct.pack('<i', ui)
        self.buffer.write(s)
        self.bufferLen+=_sizeof_int

        if self.bufferLen+_sizeof_int+ui>self.__class__.marshalBufSize: #can only happen when sending a large object - we send in multiple segments
            offset=0
            while offset<ui:
                nextSegment=self.__class__.marshalBufSize-self.bufferLen-_sizeof_int #max. size of next segment that can fit in remaining buffer
                if nextSegment>(ui-offset):
                    nextSegment=ui-offset #final segment

                self.buffer.write(ss[offset:(offset+nextSegment)])
                self.bufferLen+=nextSegment

                #todo could/should avoid final Send... i.e. if offset+nextSegment>=sdw
                if self.send()!=_ok:
                    return _fail #buffer overflow

                offset=offset+nextSegment
            #todo assert offset=sdw
            return _ok
        else: #fits in a single buffer
            self.buffer.write(ss)
            self.bufferLen+=ui

            return _ok


    def getpDataSDWORD(self):
        if self.bufferPtr+_sizeof_int>self.bufferLen:
            if self.bufferPtr==self.bufferLen:
                self.read()
            else:
                return _fail

        s=self.buffer.read(_sizeof_int)
        self.bufferPtr+=_sizeof_int
        si=struct.unpack('<i', s)[0]  #todo <I?

        if self.bufferPtr+si>self.bufferLen:
            if self.bufferPtr==self.bufferLen:
                self.read()

            #can only happen when reading a large object - we read in multiple segments (or else we must be asking for the wrong data type)
            res=cStringIO.StringIO()
            offset=0
            while offset<si:
                nextSegment=self.bufferLen-self.bufferPtr #size of next segment in remaining buffer

                res.write(self.buffer.read(nextSegment))

                self.bufferPtr=self.bufferPtr+nextSegment
                #todo could/should avoid final Read... i.e. if offset+nextSegment>=sdw
                self.read() #todo check result! abort, else we've got the next buffer full

                offset=offset+nextSegment
            #todo assert offset=sdw
            res.seek(0)
            return res.read(si)
        else: #fits in a single buffer
            self.bufferPtr=self.bufferPtr+si
            return self.buffer.read(si)


    def putSQLSMALLINT(self, si):
        return self.putSQLUSMALLINT(si)

    def getSQLPOINTER(self):
        return self.getSQLINTEGER()

    def putSQLPOINTER(self, si):
        return self.putSQLINTEGER(si)

    def putSQLUINTEGER(self, si):
        return self.putSQLINTEGER(si)

    def getSQLUINTEGER(self):
        return self.getSQLINTEGER()

    def getpSQLCHAR_SWORD(self):
        return self.getpUCHAR_SWORD()

    def putFunction(self, functionId):
        return self.putSQLUSMALLINT(functionId)

    def getFunction(self):
        return self.getSQLUSMALLINT()

    def putSQLHDBC(self, connectionHandle):
        return self.putSQLINTEGER(connectionHandle)

    def putSQLHSTMT(self, stmtHandle):
        return self.putSQLINTEGER(stmtHandle)

    def getSQLHSTMT(self):
        return self.getSQLINTEGER()

    def getRETCODE(self):
        return self.getSQLSMALLINT()


    def close(self):
        #if not self.buffer.closed:
        #    self.buffer.close()
        self.clientSocket.close()

