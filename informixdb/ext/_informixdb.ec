/************************************************************************
 *                Copyright (c) 1997 by IV DocEye AB
 *             Copyright (c) 1999 by Stephen J. Turner
 *               Copyright (c) 1999 by Carsten Haese
 *
 * By obtaining, using, and/or copying this software and/or its
 * associated documentation, you agree that you have read, understood,
 * and will comply with the following terms and conditions:
 *
 * Permission to use, copy, modify, and distribute this software and its
 * associated documentation for any purpose and without fee is hereby
 * granted, provided that the above copyright notice appears in all
 * copies, and that both that copyright notice and this permission notice
 * appear in supporting documentation, and that the name of the author
 * not be used in advertising or publicity pertaining to distribution of
 * the software without specific, written prior permission.
 *
 * THE AUTHOR DISCLAIMS ALL WARRANTIES WITH REGARD TO THIS SOFTWARE,
 * INCLUDING ALL IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS.  IN
 * NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY SPECIAL, INDIRECT OR
 * CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF
 * USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR
 * OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 ***********************************************************************/

/*
   _informixdb.ec (formerly ifxdbmodule.ec)
   $Id$
 */

#include "Python.h"
#include "structmember.h"
#include "longobject.h"
#include "cobject.h"

#include <limits.h>
#define loc_t temp_loc_t
#include <ctype.h>
#undef loc_t

#ifdef _WIN32
#include <value.h>
#include <sqlproto.h>
#else
#include <values.h>
#endif

#include <sqltypes.h>
#include <sqlstype.h>
#include <locator.h>
#include <datetime.h>

/* Use LO_RDWR to determine if the CSDK supports Smart Blobs */
#ifdef LO_RDWR
#define HAVE_SBLOB
#define SBLOB_TYPE_BLOB 0
#define SBLOB_TYPE_CLOB 1
#else
#undef HAVE_SBLOB
#endif

#if HAVE_C_DATETIME == 1
  /* Python and Informix both have a datetime.h, the Informix header is
   * included above because it comes first in the include path. We manually
   * include the Python one here (needs a few preprocessor tricks...)
   */
#   define DATETIME_INCLUDE datetime.h
#   define HACKYDT_INC2(f) #f
#   define HACKYDT_INC(f) HACKYDT_INC2(f)
#   include HACKYDT_INC(PYTHON_INCLUDE/DATETIME_INCLUDE)
#else
#   include "datetime-compat.h" /* emulate datetime API on older versions */
#endif

#ifdef IFX_THREAD
#ifndef WITH_THREAD
#error Cannot use thread-safe Informix w/o Python threads!
#else
#define IFXDB_MT
#endif
#endif

/* Python.h defines these in Python >= 2.3 */
#ifndef PyDoc_STR
#define PyDoc_VAR(name)         static char name[]
#define PyDoc_STR(str)          (str)
#define PyDoc_STRVAR(name, str) PyDoc_VAR(name) = PyDoc_STR(str)
#endif

EXEC SQL include sqlda.h;

/* This seems to be the preferred way nowadays to mark up slots which
 * can't use static initializers.
 */
#define DEFERRED_ADDRESS(ADDR) 0

/************************* Error handling *************************/

static PyObject *ExcWarning;
static PyObject *ExcError;
static PyObject *ExcInterfaceError;
static PyObject *ExcDatabaseError;
static PyObject *ExcInternalError;
static PyObject *ExcOperationalError;
static PyObject *ExcProgrammingError;
static PyObject *ExcIntegrityError;
static PyObject *ExcDataError;
static PyObject *ExcNotSupportedError;

static PyObject *IntervalY2MType;
static PyObject *IntervalD2FType;

PyDoc_STRVAR(ExcWarning_doc,
"Exception class for SQL warnings.\n\n\
The value of SQLSTATE is used to determine if a particular\n\
errorcode should be treated as Warning.\n\n\
Note: The default errorhandler never raises this exception. If the\n\
      database reports a Warning, it will be placed into the\n\
      Cursor's and Connection's messages list.");

PyDoc_STRVAR(ExcError_doc,
"Base class for all informixdb exceptions that are not Warnings.");

PyDoc_STRVAR(ExcInterfaceError_doc,
"Exception class for errors in the database interface.\n\n\
This exception is currently raised when trying to use a closed\n\
Connection or Cursor, when too few or too many parameters\n\
are passed to Cursor.execute, or when an internal datetime\n\
conversion error occurs.");

PyDoc_STRVAR(ExcDatabaseError_doc,
"Base exception class for errors related to the database.\n\n\
This exception class is the base class for more specific database\n\
errors. A generic DatabaseError will be raised when the SQLSTATE\n\
does not provide enough information to raise a more specific\n\
exception.\n\n\
All DatabaseError exceptions, and their derived classes, provide the\n\
following attributes:\n\
\n\
- sqlcode: The Informix SQLCODE associated with the error\n\
- diagnostics: A list of dictionaries with keys 'sqlstate' and\n\
               'message' that describe the error in detail.");

PyDoc_STRVAR(ExcInternalError_doc,
"Exception class for errors internal to the database.\n\n\
This exception is raised for invalid cursor or transaction states.");

PyDoc_STRVAR(ExcOperationalError_doc,
"Exception class for operational database errors that aren't\n\
necessarily under the programmer's control.\n\n\
Raised for connection problems, situations where the database runs\n\
out of memory or when the given credentials don't allow access to\n\
the database.");

PyDoc_STRVAR(ExcProgrammingError_doc,
"Exception class for errors caused by the program.\n\n\
Raised e.g. when an invalid table is referenced, a syntax error\n\
occurs or an SQL statement is invalid.");

PyDoc_STRVAR(ExcIntegrityError_doc,
"Exception class for integrity constraint violations.");

PyDoc_STRVAR(ExcDataError_doc,
"Exception class for errors that occur due to the processed data.\n\n\
Raised e.g. for a division by zero error or when a numeric value\n\
is out of range.");

PyDoc_STRVAR(ExcNotSupportedError_doc,
"Exception class for trying to use a missing or unsupported feature.\n\n\
Raised when trying to rollback a transaction on a database which\n\
doesn't support transactions or when the database doesn't support a\n\
particular feature (e.g. VARCHARs or BYTE/TEXT types on Informix SE).");

/* Checks for occurance of database errors and handles them.
 * Evaluates to 1 to indicate that an exception was raised, or to 0
 * otherwise
 */
#define is_dberror(conn, cursor, action) \
          (SQLSTATE[0] != '0' || (SQLSTATE[1] != '0' && SQLSTATE[1] != 2)) && \
          error_handle(conn, cursor, dberror_type(NULL), dberror_value(action))

#define clear_messages(obj) \
          PySequence_DelSlice(obj->messages, 0, \
                              PySequence_Length(obj->messages));

/* Checks & handles database errors and returns NULL from the current
 * function if an exception was raised.
 */
#define ret_on_dberror(conn, cursor, action) \
          if (is_dberror(conn, cursor, action)) return NULL;

#define ret_on_dberror_cursor(curs, action) \
          ret_on_dberror(curs->conn, curs, action)

#define require_open(conn) \
          if (!conn || !conn->is_open) { \
            if (error_handle(conn, NULL, ExcInterfaceError, \
                PyString_FromString("Connection already closed"))) \
              return NULL; \
          }

#define require_cursor_open(cursor) \
          do { \
            require_open(cursor->conn); \
            if (!cursor || cursor->state == 4) { \
              if (error_handle(cursor->conn, cursor, \
                           ExcInterfaceError, \
                           PyString_FromString("Cursor already closed"))) \
                return NULL; \
            }\
          } while(0)

#ifdef HAVE_SBLOB
/************************* Smart Blobs *************************/
typedef struct Sblob_t
{
  PyObject_HEAD
  struct Connection_t *conn;
  int sblob_type;
  ifx_lo_create_spec_t *lo_spec;
  ifx_lo_t lo;
  mint lofd; 
} Sblob;

static int Sblob_init(Sblob *self, PyObject *args, PyObject *kwargs);
static void Sblob_dealloc(Sblob *self);
static PyObject *Sblob_close(Sblob *self);
static PyObject *Sblob_open(Sblob *self, PyObject *args, PyObject *kwargs);
static PyObject *Sblob_read(Sblob *self, PyObject *args, PyObject *kwargs);
static PyObject *Sblob_write(Sblob *self, PyObject *args, PyObject *kwargs);
static PyObject *Sblob_seek(Sblob *self, PyObject *args, PyObject *kwargs);
static PyObject *Sblob_tell(Sblob *self);
static PyObject *Sblob_stat(Sblob *self);

static PyMethodDef Sblob_methods[] = {
  { "close", (PyCFunction)Sblob_close, METH_NOARGS },
  { "open", (PyCFunction)Sblob_open, METH_VARARGS|METH_KEYWORDS },
  { "read", (PyCFunction)Sblob_read, METH_VARARGS|METH_KEYWORDS },
  { "write", (PyCFunction)Sblob_write, METH_VARARGS|METH_KEYWORDS },
  { "seek", (PyCFunction)Sblob_seek, METH_VARARGS|METH_KEYWORDS },
  { "tell", (PyCFunction)Sblob_tell, METH_NOARGS },
  { "stat", (PyCFunction)Sblob_stat, METH_NOARGS },
  { NULL }
};

static PyMemberDef Sblob_members[] = {
  { NULL }
};

static PyGetSetDef Sblob_properties[] = {
  { NULL }
};

static PyTypeObject Sblob_type = {
  PyObject_HEAD_INIT(DEFERRED_ADDRESS(&PyType_Type))
  0,                                  /* ob_size*/
  "_informixdb.Sblob",                 /* tp_name */
  sizeof(Sblob),                       /* tp_basicsize */
  0,                                  /* tp_itemsize */
  (destructor)Sblob_dealloc,           /* tp_dealloc */
  0,                                  /* tp_print */
  0,                                  /* tp_getattr */
  0,                                  /* tp_setattr */
  0,                                  /* tp_compare */
  0,                                  /* tp_repr */
  0,                                  /* tp_as_number */
  0,                                  /* tp_as_sequence */
  0,                                  /* tp_as_mapping */
  0,                                  /* tp_hash */
  0,                                  /* tp_call */
  0,                                  /* tp_str */
  0,                                  /* tp_getattro */
  0,                                  /* tp_setattro */
  0,                                  /* tp_as_buffer */
  Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE, /* tp_flags */
  "",                                 /* tp_doc */
  0,                                  /* tp_traverse */
  0,                                  /* tp_clear */
  0,                                  /* tp_richcompare */
  0,                                  /* tp_weaklistoffset */
  0,                                  /* tp_iter */
  0,                                  /* tp_iternext */
  Sblob_methods,                       /* tp_methods */
  Sblob_members,                       /* tp_members */
  Sblob_properties,                    /* tp_getset */
  0,                                  /* tp_base */
  0,                                  /* tp_dict */
  0,                                  /* tp_descr_get */
  0,                                  /* tp_descr_set */
  0,                                  /* tp_dictoffset */
  (initproc)Sblob_init,                /* tp_init */
  PyType_GenericAlloc,                /* tp_alloc */
  PyType_GenericNew,                  /* tp_new */
  _PyObject_Del                       /* tp_free */
};
#endif

/************************* Cursors *************************/

enum CURSOR_ROWFORMAT { CURSOR_ROWFORMAT_TUPLE, CURSOR_ROWFORMAT_DICT };

typedef struct Cursor_t
{
  PyObject_HEAD
  struct Connection_t *conn;
  PyObject *description;
  int state; /* 0=free, 1=prepared, 2=declared, 3=opened, 4=closed */
  char* cursorName;
  char queryName[30];
  struct sqlda daIn;
  struct sqlda *daOut;
  int *originalType;
  int4 *originalXid;
  char *outputBuffer;
  short *indIn;
  short *indOut;
  int *parmIdx;
  int stype; /* statement type */
  PyObject *op; /* last executed operation */
  long sqlerrd[6];
  long rowcount;
  int arraysize;
  int rowformat;
  PyObject *messages;
  PyObject *errorhandler;
} Cursor;

static int Cursor_init(Cursor *self, PyObject *args, PyObject *kwargs);
static void Cursor_dealloc(Cursor *self);
static PyObject* Cursor_close(Cursor *self);
static PyObject* Cursor_execute(Cursor *self, PyObject *args, PyObject *kwds);
static PyObject* Cursor_executemany(Cursor *self, PyObject *args, PyObject *kwds);
static PyObject* Cursor_fetchone(Cursor *self);
static PyObject* Cursor_fetchmany(Cursor *self, PyObject *args, PyObject *kwds);
static PyObject* Cursor_fetchall(Cursor *self);
static PyObject* Cursor_setinputsizes(Cursor *self, PyObject *args, PyObject *kwds);
static PyObject* Cursor_setoutputsize(Cursor *self, PyObject *args, PyObject *kwds);
static PyObject* Cursor_callproc(Cursor *self, PyObject *args, PyObject *kwds);
static PyObject* Cursor_iter(Cursor *self);
static PyObject* Cursor_iternext(Cursor *self);
static PyObject *Cursor_getsqlerrd(Cursor *self, void *closure);

PyDoc_STRVAR(Cursor_close_doc,
"close()\n\n\
Close the cursor now.\n\n\
The cursor will be unusable from this point forward. Any\n\
operations on it will raise an InterfaceError.");

PyDoc_STRVAR(Cursor_execute_doc,
"execute(operation [,parameters])\n\n\
Execute an arbitrary SQL statement.\n\n\
'operation' is a string containing the SQL statements with optional\n\
placeholders, where either qmark-style\n\
(SELECT * FROM names WHERE name = ?) or numeric-style\n\
(SELECT * FROM names WHERE name = :1) may be used.\n\
\n\
'parameters' is a sequence of values to be bound to the\n\
placeholders in the SQL statement. The number of values in the\n\
sequence must match the number of parameters required by the SQL\n\
statement exactly. The data types which are used for binding are\n\
automatically derived from the Python types. For strings and\n\
integers this is straightforward. For binding date, time, datetime,\n\
and binary (BYTE/TEXT) values, the module provides constructors\n\
for constructing the corresponding Python types.");

PyDoc_STRVAR(Cursor_executemany_doc,
"executemany(operation, seq_of_parameters)\n\n\
Execute an arbitrary SQL statement multiple times using different\n\
parameters.\n\
\n\
The 'operation' parameter is the same as for execute.\n\
'seq_of_parameters' is a sequence of parameter sequences suitable\n\
for passing to execute(). The operation will be prepared once and\n\
then executes for all parameter sequences in 'seq_of_parameters'.\n\
\n\
For insert statements, executemany() will use an insert cursor\n\
if the database supports transactions. This will result in a\n\
dramatic speed increase for batch inserts.\n\
\n\
See also: Cursor.execute()");

PyDoc_STRVAR(Cursor_fetchone_doc,
"fetchone() -> tuple or dictionary\n\n\
Fetch the next row of a query result set.\n\n\
The next row is returned either as a tuple or as a dictionary,\n\
depending on how the Cursor was created (see\n\
Connection.cursor()). When no more rows are are available,\n\
None is returned.\n\n\
Calling fetchone() when no statement was executed or after\n\
a statement that does not produce a result set was executed\n\
will raise an Error.");

PyDoc_STRVAR(Cursor_fetchmany_doc,
"fetchmany([size=Cursor.arraysize]) -> list\n\n\
Fetch a specified number of rows of a query result set.\n\n\
Return up to 'size' rows in a list, or fewer if there are no more\n\
rows available. An empty list is returned if no more rows are\n\
available.\n\
\n\
See also: fetchone()");

PyDoc_STRVAR(Cursor_fetchall_doc,
"fetchall() -> list\n\n\
Fetch all remaining rows of a query result set.\n\n\
Return as many rows as there are available in the result set or an\n\
empty list if there are no more rows available.\n\
\n\
See also: fetchone()");

PyDoc_STRVAR(Cursor_setinputsizes_doc,
"setinputsizes(sizes)\n\n\
informixdb does not implement this optimization.");

PyDoc_STRVAR(Cursor_setoutputsize_doc,
"setoutputsize(size[,column])\n\n\
informixdb does not implement this optimization.");

PyDoc_STRVAR(Cursor_callproc_doc,
"callproc(procname[,parameters]) -> sequence\n\n\
Execute a stored procedure.\n\n\
Call the stored procedure 'procname' with parameters as given in\n\
the sequence 'parameters'. This is preferable to execute() with an\n\
EXECUTE PROCEDURE statement since it is portable to other DB-API 2.0\n\
implementations.\n\
\n\
Returns: The unmodified input sequence, because Informix doesn't\n\
         support \"out\" or \"in/out\" arguments for stored\n\
         procedures.");

static PyMethodDef Cursor_methods[] = {
  { "close", (PyCFunction)Cursor_close, METH_NOARGS,
    Cursor_close_doc },
  { "execute", (PyCFunction)Cursor_execute, METH_VARARGS|METH_KEYWORDS,
    Cursor_execute_doc },
  { "executemany", (PyCFunction)Cursor_executemany, METH_VARARGS|METH_KEYWORDS,
    Cursor_executemany_doc },
  { "fetchone", (PyCFunction)Cursor_fetchone, METH_NOARGS,
    Cursor_fetchone_doc },
  { "fetchmany", (PyCFunction)Cursor_fetchmany, METH_VARARGS|METH_KEYWORDS,
    Cursor_fetchmany_doc },
  { "fetchall", (PyCFunction)Cursor_fetchall, METH_NOARGS,
    Cursor_fetchall_doc },
  { "setinputsizes", (PyCFunction)Cursor_setinputsizes, METH_VARARGS|METH_KEYWORDS,
    Cursor_setinputsizes_doc },
  { "setoutputsize", (PyCFunction)Cursor_setoutputsize, METH_VARARGS|METH_KEYWORDS,
    Cursor_setoutputsize_doc },
  { "callproc", (PyCFunction)Cursor_callproc, METH_VARARGS|METH_KEYWORDS,
    Cursor_callproc_doc },
  { NULL }
};

PyDoc_STRVAR(Cursor_messages_doc,
"List of SQL warning and error messages.\n\n\
See also: Connection.messages");

PyDoc_STRVAR(Cursor_errorhandler_doc,
"Python callable which is invoked for SQL errors.\n\n\
See also: Connection.errorhandler"
);

static PyMemberDef Cursor_members[] = {
  { "description", T_OBJECT_EX, offsetof(Cursor, description), READONLY,
    "Information about result columns." },
  { "rowcount", T_LONG, offsetof(Cursor, rowcount), READONLY,
    "Number of rows returned/manipulated by last statement or -1." },
  { "arraysize", T_INT, offsetof(Cursor, arraysize), 0,
    "Number of rows to fetch in fetchmany." },
  { "messages", T_OBJECT_EX, offsetof(Cursor, messages), READONLY,
    Cursor_messages_doc }, 
  { "errorhandler", T_OBJECT_EX, offsetof(Cursor, errorhandler), 0,
    Cursor_errorhandler_doc },
  { "connection", T_OBJECT_EX, offsetof(Cursor, conn), 0,
    "Database connection associated with this cursor." },
  { NULL }
};

static PyGetSetDef Cursor_getseters[] = {
  { "sqlerrd", (getter)Cursor_getsqlerrd, NULL,
    "Informix SQL error descriptor as tuple", NULL },
  { NULL }
};

PyDoc_STRVAR(Cursor_doc,
"Executes SQL statements and fetches their results.\n\n\
Cursor objects are the central objects in interacting with the\n\
database since they provide the methods necessary to execute SQL\n\
statements and fetch results from the database.\n\
\n\
To create a Cursor object, call Connection.cursor().\n\
\n\
You can then use the execute(), executemany(), and callproc() methods\n\
to issue SQL statements and get their results with fetchone(),\n\
fetchmany(), fetchall(), or by iterating over the Cursor object.");

static PyTypeObject Cursor_type = {
  PyObject_HEAD_INIT(DEFERRED_ADDRESS(&PyType_Type))
  0,                                  /* ob_size*/
  "_informixdb.Cursor",               /* tp_name */
  sizeof(Cursor),                     /* tp_basicsize */
  0,                                  /* tp_itemsize */
  (destructor)Cursor_dealloc,         /* tp_dealloc */
  0,                                  /* tp_print */
  0,                                  /* tp_getattr */
  0,                                  /* tp_setattr */
  0,                                  /* tp_compare */
  0,                                  /* tp_repr */
  0,                                  /* tp_as_number */
  0,                                  /* tp_as_sequence */
  0,                                  /* tp_as_mapping */
  0,                                  /* tp_hash */
  0,                                  /* tp_call */
  0,                                  /* tp_str */
  0,                                  /* tp_getattro */
  0,                                  /* tp_setattro */
  0,                                  /* tp_as_buffer */
  Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE, /* tp_flags */
  Cursor_doc,                         /* tp_doc */
  0,                                  /* tp_traverse */
  0,                                  /* tp_clear */
  0,                                  /* tp_richcompare */
  0,                                  /* tp_weaklistoffset */
  (getiterfunc)Cursor_iter,           /* tp_iter */
  (iternextfunc)Cursor_iternext,      /* tp_iternext */
  Cursor_methods,                     /* tp_methods */
  Cursor_members,                     /* tp_members */
  Cursor_getseters,                   /* tp_getset */
  0,                                  /* tp_base */
  0,                                  /* tp_dict */
  0,                                  /* tp_descr_get */
  0,                                  /* tp_descr_set */
  0,                                  /* tp_dictoffset */
  (initproc)Cursor_init,              /* tp_init */
  PyType_GenericAlloc,                /* tp_alloc */
  PyType_GenericNew,                  /* tp_new */
  _PyObject_Del                       /* tp_free */
};

static void doCloseCursor(Cursor *cur, int doFree);
static void cleanInputBinding(Cursor *cur);
static void deleteInputBinding(Cursor *cur);
static void deleteOutputBinding(Cursor *cur);

/************************* Connections *************************/

typedef struct Connection_t
{
  PyObject_HEAD
  char name[30];
  int has_commit;
  int is_open;
  PyObject *messages;
  PyObject *errorhandler;
} Connection;

static int setConnection(Connection*);

static int Connection_init(Connection *self, PyObject *args, PyObject* kwds);
static void Connection_dealloc(Connection *self);
static PyObject *Connection_cursor(Connection *self, PyObject *args, PyObject *kwds);
static PyObject *Connection_commit(Connection *self);
static PyObject *Connection_rollback(Connection *self);
static PyObject *Connection_close(Connection *self);
#ifdef HAVE_SBLOB
static PyObject *Connection_Sblob(Connection *self, PyObject *args, PyObject *kwds);
#endif

PyDoc_STRVAR(Connection_cursor_doc,
"cursor([name=None,rowformat=_informixdb.ROW_AS_TUPLE]) -> Cursor\n\n\
Return a new Cursor object using the connection.\n\
\n\
'name' allows you to optionally name your cursor. This is useful\n\
for creating an update or delete cursor that can be used by a second\n\
cursor in an UPDATE (or DELETE) WHERE CURRENT OF ... statement.\n\
\n\
'rowformat' allows you to optionally specify whether the cursor\n\
should return fetched result rows as tuples or as dictionaries.");

PyDoc_STRVAR(Connection_commit_doc,
"commit()\n\n\
Commit the current database transaction and begin a new transaction.\n\n\
commit() does nothing for databases which have transactions\n\
disabled.");

PyDoc_STRVAR(Connection_rollback_doc,
"rollback()\n\n\
Rollback the current database transaction and begin a new\n\
transaction.\n\n\
rollback() raises a NotSupportedError for databases which have\n\
transactions disabled.");

PyDoc_STRVAR(Connection_close_doc,
"close()\n\n\
Close the connection and all associated Cursor objects.\n\n\
This is done automatically when the Connection object and all\n\
its associated cursors are destroyed.\n\n\
After the connection is closed it becomes unusable and all\n\
operations on it or its associated Cursor objects will raise\n\
an InterfaceError.\n\n\
For databases that have transactions enabled an implicit rollback\n\
is performed when the connection is closed, so be sure to\n\
commit any outstanding operations before closing a Connection.");

static PyMethodDef Connection_methods[] = {
  { "cursor", (PyCFunction)Connection_cursor, METH_VARARGS|METH_KEYWORDS,
    Connection_cursor_doc },
  { "commit", (PyCFunction)Connection_commit, METH_NOARGS,
    Connection_commit_doc },
  { "rollback", (PyCFunction)Connection_rollback, METH_NOARGS,
    Connection_rollback_doc },
  { "close", (PyCFunction)Connection_close, METH_NOARGS,
    Connection_close_doc },
#ifdef HAVE_SBLOB
  { "Sblob", (PyCFunction)Connection_Sblob, METH_VARARGS|METH_KEYWORDS,
    "" },
#endif
  { NULL }
};

PyDoc_STRVAR(Connection_messages_doc,
"A list with one (exception_class, exception_values) tuple for\n\
each error/warning.\n\n\
The default errorhandler appends any warnings or errors\n\
concerning the connection to this list. The list is automatically\n\
cleared by all connection methods and can be cleared manually with\n\
the command \"del connection.messages[:]\".");

PyDoc_STRVAR(Connection_errorhandler_doc,
"An optional callable which can be used to customize error reporting.\n\n\
errorhandler can be set to a callable of the form\n\
errorhandler(connection, cursor, errorclass, errorvalue)\n\
that will be called for any errors or warnings concerning the\n\
connection.\n\n\
The default (if errorhandler is None) is to append the error/warning\n\
to the messages list and raise an exception if the errorclass is not\n\
a Warning.");

static PyMemberDef Connection_members[] = {
  { "messages", T_OBJECT_EX, offsetof(Connection, messages), READONLY,
    Connection_messages_doc },
  { "errorhandler", T_OBJECT_EX, offsetof(Connection, errorhandler), 0,
    Connection_errorhandler_doc },
  { NULL }
};

static PyObject *Connection_getexception(PyObject* self, PyObject* exc)
{
  Py_INCREF(exc);
  return exc;
}

static PyGetSetDef Connection_getseters[] = {
  { "Warning", (getter)Connection_getexception, NULL,
    ExcWarning_doc, DEFERRED_ADDRESS(ExcWarning) },
  { "Error", (getter)Connection_getexception, NULL,
    ExcError_doc, DEFERRED_ADDRESS(ExcError) },
  { "InterfaceError", (getter)Connection_getexception, NULL,
    ExcInterfaceError_doc, DEFERRED_ADDRESS(ExcInterfaceError) },
  { "DatabaseError", (getter)Connection_getexception, NULL,
    ExcDatabaseError_doc, DEFERRED_ADDRESS(ExcDatabaseError) },
  { "InternalError", (getter)Connection_getexception, NULL,
    ExcInternalError_doc, DEFERRED_ADDRESS(ExcInternalError) },
  { "OperationalError", (getter)Connection_getexception, NULL,
    ExcOperationalError_doc, DEFERRED_ADDRESS(ExcOperationalError) },
  { "ProgrammingError", (getter)Connection_getexception, NULL,
    ExcProgrammingError_doc, DEFERRED_ADDRESS(ExcProgrammingError) },
  { "IntegrityError", (getter)Connection_getexception, NULL,
    ExcIntegrityError_doc, DEFERRED_ADDRESS(ExcIntegrityError) },
  { "DataError", (getter)Connection_getexception, NULL,
    ExcDataError_doc, DEFERRED_ADDRESS(ExcDataError) },
  { "NotSupportedError", (getter)Connection_getexception, NULL,
    ExcNotSupportedError_doc, DEFERRED_ADDRESS(ExcNotSupportedError) },
  { NULL }
};

PyDoc_STRVAR(Connection_doc,
"Connection to an Informix database.\n\n\
Provides access to transactions and allows the creation of Cursor\n\
objects via the cursor() method.\n\n\
As an extension to the DB-API 2.0 specification, informixdb provides\n\
the exception classes as attributes of Connection objects in addition\n\
to the module level attributes to simplify error handling in\n\
multi-connection environments.\n\n\
Do not instantiate Connection objects directly. Use the\n\
informixdb.connect() method instead.");

static PyTypeObject Connection_type = {
  PyObject_HEAD_INIT(DEFERRED_ADDRESS(&PyType_Type))
  0,                                  /* ob_size*/
  "_informixdb.Connection",           /* tp_name */
  sizeof(Connection),                 /* tp_basicsize */
  0,                                  /* tp_itemsize */
  (destructor)Connection_dealloc,     /* tp_dealloc */
  0,                                  /* tp_print */
  0,                                  /* tp_getattr */
  0,                                  /* tp_setattr */
  0,                                  /* tp_compare */
  0,                                  /* tp_repr */
  0,                                  /* tp_as_number */
  0,                                  /* tp_as_sequence */
  0,                                  /* tp_as_mapping */
  0,                                  /* tp_hash */
  0,                                  /* tp_call */
  0,                                  /* tp_str */
  0,                                  /* tp_getattro */
  0,                                  /* tp_setattro */
  0,                                  /* tp_as_buffer */
  Py_TPFLAGS_DEFAULT | Py_TPFLAGS_BASETYPE, /* tp_flags */
  Connection_doc,                     /* tp_doc */
  0,                                  /* tp_traverse */
  0,                                  /* tp_clear */
  0,                                  /* tp_richcompare */
  0,                                  /* tp_weaklistoffset */
  0,                                  /* tp_iter */
  0,                                  /* tp_iternext */
  Connection_methods,                 /* tp_methods */
  Connection_members,                 /* tp_members */
  Connection_getseters,               /* tp_getset */
  0,                                  /* tp_base */
  0,                                  /* tp_dict */
  0,                                  /* tp_descr_get */
  0,                                  /* tp_descr_set */
  0,                                  /* tp_dictoffset */
  (initproc)Connection_init,          /* tp_init */
  PyType_GenericAlloc,                /* tp_alloc */
  PyType_GenericNew,                  /* tp_new */
  _PyObject_Del                       /* tp_free */
};

static PyObject *dberror_type(PyObject *override);
static PyObject *dberror_value(char *action);
static int error_handle(Connection *connection,
                        Cursor *cursor,
                        PyObject *type, PyObject *value);

#ifdef IFXDB_MT
#define KEY "ifxdbConn"
static PyObject* ifxdbConnKey;
static char* getConnectionName(void)
{
  PyObject *dict, *conn;
  char* name;

  if (!ifxdbConnKey)
    ifxdbConnKey = PyString_FromString(KEY);

  dict = PyThreadState_GetDict();
  conn = PyDict_GetItem(dict, ifxdbConnKey);
  if (!conn) return NULL;

  name = PyString_AS_STRING(conn);
  return name;
}

static void setConnectionName(const char* name)
{
  PyObject *dict, *conn;

  if (!ifxdbConnKey)
    ifxdbConnKey = PyString_FromString(KEY);

  dict = PyThreadState_GetDict();
  if (!name) {
    PyDict_DelItem(dict, ifxdbConnKey);
  } else {
    conn = PyString_FromString(name);
    PyDict_SetItem(dict, ifxdbConnKey, conn);
    Py_DECREF(conn);
  }
}
#undef KEY
#else
static char* ifxdbConnName;
#define getConnectionName() (ifxdbConnName)
#define setConnectionName(s) (ifxdbConnName = (s))
#endif

/* returns zero on success, nonzero on failure (as with is_dberror) */
static int setConnection(Connection *conn)
{
  EXEC SQL BEGIN DECLARE SECTION;
  char *connectionName;
  EXEC SQL END DECLARE SECTION;

  /* No need to swap connection if correctly set. */
  connectionName = getConnectionName();
  if (!connectionName || strcmp(connectionName, conn->name)) {
    connectionName = conn->name;
    EXEC SQL SET CONNECTION :connectionName;
    if (is_dberror(conn, NULL, "SET-CONNECTION")) return 1;
    setConnectionName(conn->name);
  }
  return 0;
}

static PyObject *Connection_close(Connection *self)
{
  EXEC SQL BEGIN DECLARE SECTION;
  char *connectionName;
  EXEC SQL END DECLARE SECTION;

  clear_messages(self);
  require_open(self);

  if (self->has_commit) {
    if (setConnection(self)) return NULL;
    EXEC SQL ROLLBACK WORK;
    ret_on_dberror(self, NULL, "ROLLBACK");
  }

  connectionName = self->name;
  EXEC SQL DISCONNECT :connectionName;

  self->is_open = 0;

  /* success */
  Py_INCREF(Py_None);
  return Py_None;
}

static void Connection_dealloc(Connection *self)
{
  if (self->is_open) {
    Connection_close(self);
  }

  /* just in case the connection being destroyed is no longer current... */
  if (getConnectionName() == self->name)
    setConnectionName(NULL);

  Py_XDECREF(self->messages);
  Py_XDECREF(self->errorhandler);

  self->ob_type->tp_free((PyObject*)self);
}

/* If this connection has transactions, commit and
   restart transaction.
*/
static PyObject *Connection_commit(Connection *self)
{
  clear_messages(self);
  require_open(self);

  if (self->has_commit) {
    if (setConnection(self)) return NULL;
    EXEC SQL COMMIT WORK;
    ret_on_dberror(self, NULL, "COMMIT");

    EXEC SQL BEGIN WORK;
    ret_on_dberror(self, NULL, "BEGIN");
  }
  /* success */
  Py_INCREF(Py_None);
  return Py_None;
}

/*
 Pretty much the same as COMMIT operation.
 We ROLLBACK and restart transaction but this has only meaning if there
 is support for transactions.
 */
static PyObject *Connection_rollback(Connection *self)
{
  clear_messages(self);
  require_open(self);

  if (setConnection(self)) return NULL;

  if (self->has_commit) {
    EXEC SQL ROLLBACK WORK;
    ret_on_dberror(self, NULL, "ROLLBACK");
  } else {
    error_handle(self, NULL,
                 ExcNotSupportedError, dberror_value("ROLLBACK"));
    return NULL;
  }

  EXEC SQL BEGIN WORK;
  ret_on_dberror(self, NULL, "BEGIN");

  Py_INCREF(Py_None);
  return Py_None;
}

/* Begin section for parser of sql statements w.r.t.
   dynamic variable binding.
*/
typedef struct {
  const char *ptr;
  char *out;
  int parmCount;
  int parmIdx;
  int isParm;
  char state;
  char prev;
} parseContext;

static void initParseContext(parseContext *ct, const char *c, char *out)
{
  ct->state = 0;
  ct->ptr = c;
  ct->out = out;
  ct->parmCount = 0;
  ct->parmIdx = 0;
  ct->prev = '\0';
}

static int doParse(parseContext *ct)
{
  int rc = 0;
  register const char *in = ct->ptr;
  register char *out = ct->out;
  register char ch;

  ct->isParm = 0;
  while ( (ch = *in++) ) {
    if (ct->state == ch) {
      ct->state = 0;
    } else if (ct->state == 0){
      if ((ch == '\'') || (ch == '"')) {
        ct->state = ch;
      } else if (ch == '?') {
        ct->parmIdx = ct->parmCount;
        ct->parmCount++;
        ct->isParm = 1;
        rc = 1;
        break;
      } else if ((ch == ':') && !isalnum(ct->prev)) {
        const char *m = in;
        int n = 0;
        while (isdigit(*m)) {
          n *= 10;
          n += *m - '0';
          m++;
        }
        if (n) {
          ct->parmIdx = n-1;
          ct->parmCount++;
          in = m;
          ct->isParm = 1;
          ct->prev = '0';
          rc = 1;
          break;
        }
      }
    }
    ct->prev = *out++ = ch;
  }

  *out++ = rc ? '?' : 0;
  ct->ptr = in;
  ct->out = out;
  return rc;
}

static int ibindBinary(struct sqlvar_struct *var, PyObject *item)
{
  char *buf;
  int n;
  loc_t *loc;

  if (PyObject_AsReadBuffer(item, (const void**)&buf, &n) == -1) {
    return 0;
  }

  loc = (loc_t*) malloc(sizeof(loc_t));
  loc->loc_loctype = LOCMEMORY;
  loc->loc_buffer = malloc(n);
  loc->loc_bufsize = n;
  loc->loc_size = n;
  loc->loc_oflags = 0;
  loc->loc_mflags = 0;
  loc->loc_indicator = 0;
  memcpy(loc->loc_buffer, buf, n);

  var->sqldata = (char *) loc;
  var->sqllen = sizeof(loc_t);
  var->sqltype = CLOCATORTYPE;
  *var->sqlind = 0;
  return 1;
}

static int ibindDateTime(struct sqlvar_struct *var, PyObject *datetime)
{
  int year,month,day,hour,minute,second,usec,ret;
  dtime_t* dt;
  char buf[26];

  year = PyDateTime_GET_YEAR(datetime);
  month = PyDateTime_GET_MONTH(datetime);
  day = PyDateTime_GET_DAY(datetime);
  hour = PyDateTime_DATE_GET_HOUR(datetime);
  minute = PyDateTime_DATE_GET_MINUTE(datetime);
  second = PyDateTime_DATE_GET_SECOND(datetime);
  usec = PyDateTime_DATE_GET_MICROSECOND(datetime);

  dt = (dtime_t*)malloc(sizeof(dtime_t));
  dt->dt_qual = TU_DTENCODE(TU_YEAR, TU_F5);
  snprintf(buf, sizeof(buf), "%d-%d-%d %d:%d:%d.%d", year, month, day,
           hour, minute, second, usec/10);
  if ((ret = dtcvasc(buf, dt)) != 0) {
    PyErr_Format(ExcInterfaceError, "Failed to parse datetime value (%s). "
                 "dtcvasc() returned: %d", buf, ret);
    return 0;
  }

  var->sqldata = (char*)dt;
  var->sqllen = sizeof(dtime_t);
  var->sqltype = CDTIMETYPE;
  *var->sqlind = 0;

  return 1;
}

static int ibindDate(struct sqlvar_struct *var, PyObject *date)
{
  short mdy_date[3];
  int ret;
  long *d= (long*)malloc(sizeof(long));
  mdy_date[2] = PyDateTime_GET_YEAR(date);
  mdy_date[1] = PyDateTime_GET_DAY(date);
  mdy_date[0] = PyDateTime_GET_MONTH(date);

  if ((ret = rmdyjul(mdy_date, d)) != 0) {
    PyErr_Format(ExcInterfaceError, "Failed to parse convert value "
                 "(%4d-%2d-%2d). rmdyjul() returned: %d",
                 mdy_date[2], mdy_date[0], mdy_date[1], ret);
    return 0;
  }

  var->sqldata = (char*)d;
  var->sqllen = sizeof(long);
  var->sqltype = CDATETYPE;
  *var->sqlind = 0;

  return 1;
}

static int ibindString(struct sqlvar_struct *var, PyObject *item)
{
  PyObject *sitem;
  const char *val;
  int n;
#if HAVE_PY_BOOL == 1
  if (PyBool_Check(item)) {
    item = PyNumber_Int(item);
  }
#endif
  sitem = PyObject_Str(item);
  val = PyString_AS_STRING((PyStringObject*)sitem);
  n = strlen(val);
EXEC SQL ifdef SQLLVARCHAR;
  if (n >= 32768) {
    /* use lvarchar* instead */
    EXEC SQL BEGIN DECLARE SECTION;
    lvarchar **data;
    EXEC SQL END DECLARE SECTION;
    data = malloc(sizeof(void*));
    *data = 0;
    ifx_var_flag(data, 0);
    ifx_var_alloc(data, n+1);
    ifx_var_setlen(data, n);
    ifx_var_setdata(data, (char *)val, n);
    var->sqltype = SQLUDTVAR;
    var->sqlxid = XID_LVARCHAR;
    var->sqldata = *data;
    var->sqllen  = sizeof(void*);
    *var->sqlind = 0;
    free( data );
  }
  else
EXEC SQL endif;
  {
    var->sqltype = CSTRINGTYPE;
    var->sqldata = malloc(n+1);
    var->sqllen = n+1;
    *var->sqlind = 0;
    memcpy(var->sqldata, val, n+1);
  }
  Py_DECREF(sitem);
  return 1;
}

static int ibindInterval(struct sqlvar_struct *var, PyObject *item)
{
  PyObject *sitem = PyObject_Str(item);
  const char *val = PyString_AS_STRING((PyStringObject*)sitem);
  intrvl_t *inv = (intrvl_t*)malloc(sizeof(intrvl_t));
  int ret;

  if (PyObject_IsInstance(item, IntervalY2MType))
     inv->in_qual = TU_IENCODE(9,TU_YEAR,TU_MONTH);
  else
     inv->in_qual = TU_IENCODE(9,TU_DAY,TU_F5);

  if ((ret = incvasc((char *)val, inv)) != 0) {
    PyErr_Format(ExcInterfaceError,
      "Failed to parse interval value %s. incvasc returned %d", val, ret);
    return 0;
  }

  var->sqldata = (void*)inv;
  var->sqllen = sizeof(intrvl_t);
  var->sqltype = CINVTYPE;
  *var->sqlind = 0;
  return 1;
}

#ifdef HAVE_SBLOB
static int ibindSblob(struct sqlvar_struct *var, PyObject *item)
{
  Sblob *sblob = (Sblob*)item;
  ifx_lo_t *data = malloc(sizeof(ifx_lo_t));
  memcpy(data, &(sblob->lo), sizeof(ifx_lo_t));
  var->sqltype = SQLUDTFIXED;
  if (sblob->sblob_type==SBLOB_TYPE_CLOB) 
    var->sqlxid = XID_CLOB;
  else
    var->sqlxid = XID_BLOB;
  var->sqldata = (void*)data;
  var->sqllen  = sizeof(ifx_lo_t);
  *var->sqlind = 0;
  return 1;
}
#endif

static int ibindNone(struct sqlvar_struct *var, PyObject *item)
{
  var->sqltype = CSTRINGTYPE;
  var->sqldata = NULL;
  var->sqllen = 0;
  *var->sqlind = -1;
  return 1;
}

typedef int (*ibindFptr)(struct sqlvar_struct *, PyObject*);

static ibindFptr ibindFcn(PyObject* item)
{
#ifdef HAVE_SBLOB
  if (PyObject_IsInstance(item, (PyObject*)&Sblob_type)) {
    return ibindSblob;
  } else
#endif
  if (PyObject_IsInstance(item, IntervalY2MType) ||
      PyObject_IsInstance(item, IntervalD2FType)) {
    return ibindInterval;
  } else if (PyBuffer_Check(item)) {
    return ibindBinary;
  } else if (PyDateTime_Check(item)) {
    return (ibindFptr)ibindDateTime;
  } else if (PyDate_Check(item)) {
    return (ibindFptr)ibindDate;
  } else if(item == Py_None) {
    return ibindNone;
  } else {
    return ibindString;
  }
}

static void allocSlots(Cursor *cur, int n_slots)
{
  cur->daIn.sqld = n_slots;
  cur->daIn.sqlvar = calloc(n_slots, sizeof(struct sqlvar_struct));
  cur->indIn = calloc(n_slots, sizeof(short));
}

#define PARM_COUNT_GUESS 4
#define PARM_COUNT_INCREMENT 4
static int parseSql(Cursor *cur, register char *out, const char *in)
{
  parseContext ctx;
  int i, n_slots;
  struct sqlvar_struct *var;
  short *ind;

  n_slots = PARM_COUNT_GUESS;
  cur->parmIdx = malloc(PARM_COUNT_GUESS * sizeof(int));

  initParseContext(&ctx, in, out);
  while (doParse(&ctx)) {
    cur->parmIdx[ctx.parmCount-1] = ctx.parmIdx;
    if (ctx.parmCount == n_slots) {
      n_slots += PARM_COUNT_INCREMENT;
      cur->parmIdx = realloc(cur->parmIdx, n_slots * sizeof(int));
    }
  }

  if (ctx.parmCount == 0) {
    free(cur->parmIdx);
    cur->parmIdx = NULL;
  } else if (ctx.parmCount < n_slots)
    cur->parmIdx = realloc(cur->parmIdx, ctx.parmCount * sizeof(int));

  allocSlots(cur, ctx.parmCount);
  var = cur->daIn.sqlvar;
  ind = cur->indIn;
  for (i = 0; i < ctx.parmCount; ++i)
    (var++)->sqlind = ind++;

  return 1;
}

static int bindInput(Cursor *cur, PyObject *vars)
{
  struct sqlvar_struct *var = cur->daIn.sqlvar;
  int n_vars = vars ? PyObject_Length(vars) : 0;
  int i;
  int maxp=0;

  if (vars && !PySequence_Check(vars)) {
    PyErr_SetString(PyExc_TypeError, "SQL parameters are not a sequence");
    return 0;
  }

  for (i = 0; i < cur->daIn.sqld; ++i) {
    if (cur->parmIdx[i] < n_vars) {
      int success;
      PyObject *item = PySequence_GetItem(vars, cur->parmIdx[i]);

      success = (*ibindFcn(item))(var++, item);
      Py_DECREF(item);  /* PySequence_GetItem increments it */
      if (!success)
        return 0;
      maxp = maxp > cur->parmIdx[i] ? maxp : cur->parmIdx[i];
    } else {
      error_handle(cur->conn, cur, ExcInterfaceError,
                   PyString_FromString("too few actual parameters"));
      return 0;
    }
  }

  if (maxp+1 < n_vars) {
    error_handle(cur->conn, cur, ExcInterfaceError,
                 PyString_FromString("too many actual parameters"));
    return 0;
  }

  return 1;
}

static void bindOutput(Cursor *cur)
{
  char * bufp;
  int pos;
  int count = 0;
  struct sqlvar_struct *var;

  cur->indOut = calloc(cur->daOut->sqld, sizeof(short));
  cur->originalType = calloc(cur->daOut->sqld, sizeof(int));
  cur->originalXid = calloc(cur->daOut->sqld, sizeof(int4));

  Py_DECREF(cur->description);
  cur->description = PyTuple_New(cur->daOut->sqld);
  for (pos = 0, var = cur->daOut->sqlvar;
       pos < cur->daOut->sqld;
       pos++, var++) {
    PyObject *new_tuple = Py_BuildValue("(sNiiOOi)",
                                        var->sqlname,
                                        PyString_FromString(rtypname(var->sqltype)),
                                        var->sqllen,
                                        var->sqllen,
                                        Py_None, Py_None,
                                        !(var->sqltype & SQLNONULL));
    PyTuple_SET_ITEM(cur->description, pos, new_tuple);

    var->sqlind = &cur->indOut[pos];
    cur->originalType[pos] = var->sqltype;
    cur->originalXid[pos] = var->sqlxid;

    switch(var->sqltype & SQLTYPE){
    case SQLBYTES:
    case SQLTEXT:
      var->sqllen  = sizeof(loc_t);
      var->sqltype = CLOCATORTYPE;
      break;
    case SQLSMFLOAT:
      var->sqltype = CFLOATTYPE;
      break;
    case SQLFLOAT:
      var->sqltype = CDOUBLETYPE;
      break;
    case SQLDECIMAL:
      var->sqltype = CDECIMALTYPE;
      break;
    case SQLMONEY:
      var->sqltype = CMONEYTYPE;
      break;
    case SQLDATE:
      var->sqltype = CDATETYPE;
      break;
    case SQLSMINT:
      var->sqltype = CSHORTTYPE;
      break;
    case SQLINT:
    case SQLSERIAL:
      var->sqltype = CLONGTYPE;
      break;
#ifdef SQLINT8
    case SQLINT8:
    case SQLSERIAL8:
      var->sqltype = CCHARTYPE;
      var->sqllen = 20;
      break;
#endif
    case SQLDTIME:
      var->sqltype = CDTIMETYPE;
      break;
    case SQLINTERVAL:
      var->sqltype = CINVTYPE;
      break;
    default:
#ifdef HAVE_SBLOB
        if (ISSMARTBLOB(var->sqltype, var->sqlxid))
          ; /* do nothing */
        else
#endif
#ifdef CLVCHARPTRTYPE
        if (ISCOMPLEXTYPE(var->sqltype) || ISUDTTYPE(var->sqltype))
          var->sqltype = CLVCHARPTRTYPE;
        else
#endif
          var->sqltype = CCHARTYPE;
      break;

    }
#ifdef HAVE_SBLOB
    if (!ISSMARTBLOB(var->sqltype, var->sqlxid)) {
#endif
    var->sqllen = rtypmsize(var->sqltype, var->sqllen);
    count = rtypalign(count, var->sqltype) + var->sqllen;
#ifdef HAVE_SBLOB
    }
#endif
  }

  bufp = cur->outputBuffer = malloc(count);

  for (pos = 0, var = cur->daOut->sqlvar;
       pos < cur->daOut->sqld;
       pos++, var++) {
    bufp = (char *) rtypalign( (int) bufp, var->sqltype);

#ifdef HAVE_SBLOB
    if (ISSMARTBLOB(var->sqltype, var->sqlxid)) {
      var->sqldata = malloc(sizeof(ifx_lo_t));
    }
    else
#endif
    if (var->sqltype == CLOCATORTYPE) {
      loc_t *loc = (loc_t*) bufp;
      loc->loc_loctype = LOCMEMORY;
      loc->loc_bufsize = -1;
      loc->loc_oflags = 0;
      loc->loc_mflags = 0;
    }
EXEC SQL ifdef SQLLVARCHAR;
    else if (var->sqltype == CLVCHARPTRTYPE )
    {
      exec sql begin declare section;
      lvarchar **currentlvarcharptr;
      exec sql end declare section;

      currentlvarcharptr = malloc(sizeof(void *));
      *currentlvarcharptr = 0;
      ifx_var_flag(currentlvarcharptr,1);

      var->sqlxid = 1;
      var->sqldata = *currentlvarcharptr;
      var->sqllen  = sizeof(void *);
    }
EXEC SQL endif;
    else {
      var->sqldata = bufp;
      bufp += var->sqllen;
    }

    if (var->sqltype == CDTIMETYPE || var->sqltype == CINVTYPE) {
      /* let the database set the correct datetime format */
      var->sqllen = 0;
    }
  }
}

static PyObject *Cursor_getsqlerrd(Cursor *self, void* closure)
{
  return Py_BuildValue("(iiiiii)",
    self->sqlerrd[0], self->sqlerrd[1], self->sqlerrd[2],
    self->sqlerrd[3], self->sqlerrd[4], self->sqlerrd[5]);
}

static PyObject *Cursor_execute(Cursor *self, PyObject *args, PyObject *kwds)
{
  struct sqlda *tdaIn = &self->daIn;
  struct sqlda *tdaOut = self->daOut;
  PyObject *op, *inputvars=NULL;
  const char *sql;
  int i;
  static char* kwdlist[] = { "operation", "parameters", 0 };
  EXEC SQL BEGIN DECLARE SECTION;
  char *queryName = self->queryName;
  char *cursorName = self->cursorName;
  char *newSql;
  EXEC SQL END DECLARE SECTION;

  clear_messages(self);
  require_cursor_open(self);

  if (!PyArg_ParseTupleAndKeywords(args, kwds, "s|O", kwdlist,
                                   &sql, &inputvars))
    return NULL;
  op = PyTuple_GET_ITEM(args, 0);

  /* Make sure we talk to the right database. */
  if (setConnection(self->conn)) return NULL;

  if (op == self->op) {
    doCloseCursor(self, 0);
    cleanInputBinding(self);
  } else {
    doCloseCursor(self, 1);
    deleteInputBinding(self);
    deleteOutputBinding(self);

    /* `newSql' may be shorter than but will never exceed length of `sql' */
    newSql = malloc(strlen(sql) + 1);
    if (!parseSql(self, newSql, sql)) {
      free(newSql);
      return 0;
    }
    EXEC SQL PREPARE :queryName FROM :newSql;
    for (i=0; i<6; i++) self->sqlerrd[i] = sqlca.sqlerrd[i];
    free(newSql);
    ret_on_dberror_cursor(self, "PREPARE");
    self->state = 1;

    EXEC SQL DESCRIBE :queryName INTO tdaOut;
    self->daOut = tdaOut;
    self->stype = SQLCODE;

    if (self->stype == 0 || self->stype == SQ_EXECPROC) {
      bindOutput(self);

      EXEC SQL DECLARE :cursorName CURSOR FOR :queryName;
      ret_on_dberror_cursor(self, "DECLARE");
      EXEC SQL FREE :queryName;
      ret_on_dberror_cursor(self, "FREE");
      self->state = 2;
    } else {
      free(self->daOut);
      self->daOut = NULL;
    }

    /* cache operation reference */
    self->op = op;
    Py_INCREF(op);
  }

  if (!bindInput(self, inputvars))
    return 0;

  if (self->stype == 0 || self->stype == SQ_EXECPROC) {
    EXEC SQL OPEN :cursorName USING DESCRIPTOR tdaIn;
    ret_on_dberror_cursor(self, "OPEN");
    self->state = 3;

    for (i=0; i<6; i++) self->sqlerrd[i] = sqlca.sqlerrd[i];
    self->rowcount = -1;
    Py_INCREF(Py_None);
    return Py_None;
  } else {
    Py_BEGIN_ALLOW_THREADS;
    EXEC SQL EXECUTE :queryName USING DESCRIPTOR tdaIn;
    Py_END_ALLOW_THREADS;
    ret_on_dberror_cursor(self, "EXECUTE");

    for (i=0; i<6; i++) self->sqlerrd[i] = sqlca.sqlerrd[i];
    switch (self->stype) {
      case SQ_UPDATE:
      case SQ_UPDCURR:
      case SQ_UPDALL:
      case SQ_DELETE:
      case SQ_DELCURR:
      case SQ_DELALL:
      case SQ_INSERT:
        self->rowcount = sqlca.sqlerrd[2];
        break;
      default:
        self->rowcount = -1;
        break;
    }

    return Py_BuildValue("i", self->rowcount); /* number of row */
  }
  /* error return */
  return NULL;
}

static PyObject *Cursor_executemany(Cursor *self,
                                    PyObject *args,
                                    PyObject *kwds)
{
  struct sqlda *tdaIn = &self->daIn;
  struct sqlda *tdaOut = self->daOut;
  PyObject *op, *params, *inputvars = 0;
  const char *sql;
  int i, len;
  int rowcount = 0, inputDirty = 0, useInsertCursor;
  static char* kwdlist[] = { "operation", "seq_of_parameters", 0 };
  EXEC SQL BEGIN DECLARE SECTION;
  char *queryName = self->queryName;
  char *cursorName = self->cursorName;
  char *newSql;
  EXEC SQL END DECLARE SECTION;

  clear_messages(self);
  require_cursor_open(self);

  if (!PyArg_ParseTupleAndKeywords(args, kwds, "sO", kwdlist, &sql, &params))
    return NULL;
  op = PyTuple_GET_ITEM(args, 0);
  len = PySequence_Size(params);
  if (len == -1) {
    PyErr_SetString(PyExc_TypeError, "Parameter must be a sequence");
    return NULL;
  }

  /* Make sure we talk to the right database. */
  if (setConnection(self->conn)) return NULL;

  if (op == self->op) {
    doCloseCursor(self, 0);
    cleanInputBinding(self);
    useInsertCursor =
      (self->conn->has_commit && self->stype==SQ_INSERT);
  } else {
    doCloseCursor(self, 1);
    deleteInputBinding(self);
    deleteOutputBinding(self);

    /* `newSql' may be shorter than but will never exceed length of `sql' */
    newSql = malloc(strlen(sql) + 1);
    if (!parseSql(self, newSql, sql)) {
      free(newSql);
      return 0;
    }
    EXEC SQL PREPARE :queryName FROM :newSql;
    for (i=0; i<6; i++) self->sqlerrd[i] = sqlca.sqlerrd[i];
    free(newSql);
    ret_on_dberror_cursor(self, "PREPARE");
    self->state = 1;

    EXEC SQL DESCRIBE :queryName INTO tdaOut;
    self->daOut = tdaOut;
    self->stype = SQLCODE;

    if (self->stype == 0) {
      bindOutput(self);

      EXEC SQL DECLARE :cursorName CURSOR FOR :queryName;
      ret_on_dberror_cursor(self, "DECLARE");
      EXEC SQL FREE :queryName;
      ret_on_dberror_cursor(self, "FREE");
      self->state = 2;
    } else {
      free(self->daOut);
      self->daOut = NULL;
    }

    useInsertCursor =
      (self->conn->has_commit && self->stype==SQ_INSERT);

    if (useInsertCursor) {
      EXEC SQL DECLARE :cursorName CURSOR FOR :queryName;
      ret_on_dberror_cursor(self, "DECLARE");
      EXEC SQL FREE :queryName;
      ret_on_dberror_cursor(self, "FREE");
      self->state = 2;
    }

    /* cache operation reference */
    self->op = op;
    Py_INCREF(op);
  }

  if (useInsertCursor) {
    EXEC SQL OPEN :cursorName;
    ret_on_dberror_cursor(self, "OPEN");
    self->state = 3;
  }

  for (i=0; i<len; i++) {
    inputvars = PySequence_GetItem(params, i);
    if (inputDirty) {
      cleanInputBinding(self);
    }
    if (!bindInput(self, inputvars))
      return 0;
    inputDirty = 1;

    if (self->stype == 0) {
      EXEC SQL OPEN :cursorName USING DESCRIPTOR tdaIn;
      ret_on_dberror_cursor(self, "OPEN");
      self->state = 3;

      rowcount = -1;
    } else {
      Py_BEGIN_ALLOW_THREADS;
      if (useInsertCursor) {
        EXEC SQL PUT :cursorName USING DESCRIPTOR tdaIn;
      } else {
        EXEC SQL EXECUTE :queryName USING DESCRIPTOR tdaIn;
      }
      Py_END_ALLOW_THREADS;
      ret_on_dberror_cursor(self, "EXECUTE");

      switch (self->stype) {
        case SQ_UPDATE:
        case SQ_UPDCURR:
        case SQ_UPDALL:
        case SQ_DELETE:
        case SQ_DELCURR:
        case SQ_DELALL:
        case SQ_INSERT:
          rowcount += sqlca.sqlerrd[2];
          break;
        default:
          rowcount = -1;
          break;
      }
    }
    Py_DECREF(inputvars);
  }
  if (useInsertCursor) {
    Py_BEGIN_ALLOW_THREADS;
    EXEC SQL FLUSH :cursorName;
    Py_END_ALLOW_THREADS;
    rowcount += sqlca.sqlerrd[2];
  }

  self->rowcount = rowcount;
  for (i=0; i<6; i++) self->sqlerrd[i] = sqlca.sqlerrd[i];
  Py_INCREF(Py_None);
  return Py_None;
}

static PyObject *CallObjectAndDiscardArgs(PyObject *t, PyObject *a)
{
  PyObject *result;
  result = PyObject_CallObject(t, a);
  Py_DECREF(a);
  return result;
} 
  
static PyObject *doCopy(/* const */ void *data, int type, int4 xid,
                                    struct Connection_t *conn)
{
  switch(type){
  case SQLDATE:
  {
    short mdy_date[3];
    rjulmdy(*(long*)data, mdy_date);
    return PyDate_FromDate(mdy_date[2], mdy_date[0], mdy_date[1]);
  }
  case SQLDTIME:
  {
    int i, pos;
    int year=1,month=1,day=1,hour=0,minute=0,second=0,usec=0;
    dtime_t* dt = (dtime_t*)data;
    for (pos = 0, i = TU_START(dt->dt_qual); i <= TU_END(dt->dt_qual); ++i) {
      switch (i) {
      case TU_YEAR:
        year = dt->dt_dec.dec_dgts[pos++]*100;
        year += dt->dt_dec.dec_dgts[pos++];
        break;
      case TU_MONTH:
        month = dt->dt_dec.dec_dgts[pos++];
        break;
      case TU_DAY:
        day = dt->dt_dec.dec_dgts[pos++];
        break;
      case TU_HOUR:
        hour = dt->dt_dec.dec_dgts[pos++];
        break;
      case TU_MINUTE:
        minute = dt->dt_dec.dec_dgts[pos++];
        break;
      case TU_SECOND:
        second = dt->dt_dec.dec_dgts[pos++];
        break;
      case TU_F1:
        usec += dt->dt_dec.dec_dgts[pos++] * 10000;
        break;
      case TU_F3:
        usec += dt->dt_dec.dec_dgts[pos++] * 100;
        break;
      case TU_F5:
        usec += dt->dt_dec.dec_dgts[pos++];
        break;
      }
    }
    return PyDateTime_FromDateAndTime(year, month, day,
                                      hour, minute, second, usec);
  }
  case SQLINTERVAL:
  {
    /* Informix stores an interval as a decimal number, which in turn is
       stored as a sequence of base 100 "digits." Since the starting unit
       may span several base-100 digits, I extend the given interval to
       the full length of its interval class, so that the starting unit,
       is either the year or the day.  This leads to the two following cases:

       Year(9) to Month
           decimal digits: 0YYYYYYYYYMM00000000.00000
        base-100 position: 10_9_8_7_6_5_4_3_2_1 _0-1-2

       Day(9) to Fraction(5)
           decimal digits: 0DDDDDDDDDHHMMSS.FFFFF
        base-100 position: _8_7_6_5_4_3_2_1 _0-1-2
    */     
    int i, pos, d, sign=0;
    int year=0,month=0,day=0,hour=0,minute=0,second=0,usec=0;
    intrvl_t* inv = (intrvl_t*)data;
    sign = (inv->in_dec.dec_pos==0)?-1:1;
    if (TU_START(inv->in_qual) <= TU_MONTH) {
      exec sql begin declare section;
      interval year(9) to month inv_extended;
      exec sql end declare section;
      invextend(inv, &inv_extended);
      inv = &inv_extended;
      pos = inv->in_dec.dec_exp;
      for (i=0; i<inv->in_dec.dec_ndgts; i++) {
        d = inv->in_dec.dec_dgts[i];
        switch(pos) {
          case 10: case 9: case 8: case 7: case 6:
            year = 100*year + d; break;
          case 5: month = d; break;
        }
        pos--;
      }
      return CallObjectAndDiscardArgs(IntervalY2MType,
               Py_BuildValue("(ii)",sign*year,sign*month) );
    }
    else {
      exec sql begin declare section;
      interval day(9) to fraction(5) inv_extended;
      exec sql end declare section;
      invextend(inv, &inv_extended);
      inv = &inv_extended;
      pos = inv->in_dec.dec_exp;
      for (i=0; i<inv->in_dec.dec_ndgts; i++) {
        d = inv->in_dec.dec_dgts[i];
        switch(pos) {
          case 8: case 7: case 6: case 5: case 4:
            day = 100*day + d; break;
          case  3: hour = d; break;
          case  2: minute = d; break;
          case  1: second = d; break;
          case  0: usec += 10000*d; break;
          case -1: usec +=   100*d; break;
          case -2: usec +=       d; break;
        }
        pos--;
      }
      return CallObjectAndDiscardArgs(IntervalD2FType,
               Py_BuildValue("(iii)", sign*day,
                      sign*(3600*hour+60*minute+second), sign*usec) );
    }
  }
  case SQLCHAR:
  case SQLVCHAR:
  case SQLNCHAR:
  case SQLNVCHAR:
#ifdef SQLLVARCHAR
  case SQLLVARCHAR:
#endif
  {
      /* clip trailing spaces */
      register size_t len = strlen((char*)data);
      register size_t clipped_len = byleng(data, len);
      ((char*)data)[clipped_len] = 0;
      return Py_BuildValue("s", (char*)data);
  }
  case SQLFLOAT:
    return PyFloat_FromDouble(*(double*)data);
  case SQLSMFLOAT:
    return PyFloat_FromDouble(*(float*)data);
  case SQLDECIMAL:
  case SQLMONEY:
  {
    double dval;
    dectodbl((dec_t*)data, &dval);
    return PyFloat_FromDouble(dval);
  }
  case SQLSMINT:
    return PyInt_FromLong(*(short*)data);
  case SQLINT:
  case SQLSERIAL:
    return PyInt_FromLong(*(long*)data);
#ifdef SQLINT8
  case SQLINT8:
  case SQLSERIAL8:
    return PyLong_FromString((char *)data, NULL, 10);
#endif
  case SQLBYTES:
  case SQLTEXT:
  {
    PyObject *buffer;
    char *b_mem;
    int b_len;
    loc_t *l = (loc_t*)data;

    l->loc_mflags |= LOC_ALLOC;
    buffer = PyBuffer_New(l->loc_size);

    if (PyObject_AsWriteBuffer(buffer, (void**)&b_mem, &b_len) == -1) {
      Py_DECREF(buffer);
      return NULL;
    }

    memcpy(b_mem, l->loc_buffer, b_len);
    return buffer;
  } /* case SQLTEXT */
  } /* switch */
#ifdef HAVE_SBLOB
  if (ISSMARTBLOB(type,xid)) {
      Sblob *new_sblob;
      new_sblob = (Sblob*)CallObjectAndDiscardArgs((PyObject*)&Sblob_type,
               Py_BuildValue("(Oi)", conn, 0) );
      memcpy(&new_sblob->lo, data, sizeof(ifx_lo_t));
      if (xid==XID_CLOB)
        new_sblob->sblob_type = SBLOB_TYPE_CLOB;
      else
        new_sblob->sblob_type = SBLOB_TYPE_BLOB;
      return (PyObject*)new_sblob;
  } else
#endif
#ifdef CLVCHARPTRTYPE
  if (ISCOMPLEXTYPE(type)||ISUDTTYPE(type)) {
    PyObject *buffer;
    int lvcharlen = ifx_var_getlen(&data);
    void *lvcharbuf = ifx_var_getdata(&data);
    char *b_mem;
    int b_len;

    buffer = PyBuffer_New(lvcharlen);

    if (PyObject_AsWriteBuffer(buffer, (void**)&b_mem, &b_len) == -1) {
      Py_DECREF(buffer);
      return NULL;
    }

    memcpy(b_mem, lvcharbuf, b_len);
    ifx_var_dealloc(&data);
    return buffer;
  }
#endif
  Py_INCREF(Py_None);
  return Py_None;
}

static PyObject *processOutput(Cursor *cur)
{
  PyObject *row;
  int pos;
  struct sqlvar_struct *var;
  if (cur->rowformat == CURSOR_ROWFORMAT_DICT) {
    row = PyDict_New();
  } else {
    row = PyTuple_New(cur->daOut->sqld);
  }

  for (pos = 0, var = cur->daOut->sqlvar;
       pos < cur->daOut->sqld;
       pos++, var++) {

    PyObject *v;
    if (*var->sqlind < 0) {
      v = Py_None;
      Py_INCREF(v);
    } else {
      v = doCopy(var->sqldata, cur->originalType[pos], cur->originalXid[pos],
                 cur->conn);
    }

    if (cur->rowformat == CURSOR_ROWFORMAT_DICT) {
      PyDict_SetItemString(row, var->sqlname, v);
    } else {
      PyTuple_SET_ITEM(row, pos, v);
    }
  }
  return row;
}

static PyObject *Connection_cursor(Connection *self, PyObject *args, PyObject *kwds)
{
  PyObject *a, *cur;
  int i;

  require_open(self);

  a = PyTuple_New(PyTuple_Size(args) + 1);
  Py_INCREF(self);
  PyTuple_SET_ITEM(a, 0, (PyObject*)self);
  for (i = 0; i < PyTuple_Size(args); ++i) {
    PyObject *o = PyTuple_GetItem(args, i);
    Py_INCREF(o);
    PyTuple_SET_ITEM(a, i+1, o);
  }

  cur = PyObject_Call((PyObject*)&Cursor_type, a, kwds);
  Py_DECREF(a);
  return cur;
}

#ifdef HAVE_SBLOB
static PyObject *Connection_Sblob(Connection *self, PyObject *args, PyObject *kwds)
{
  PyObject *a, *slob;
  int i;

  require_open(self);

  a = PyTuple_New(PyTuple_Size(args) + 2);
  Py_INCREF(self);
  PyTuple_SET_ITEM(a, 0, (PyObject*)self);
  PyTuple_SET_ITEM(a, 1, PyInt_FromLong(1));
  for (i = 0; i < PyTuple_Size(args); ++i) {
    PyObject *o = PyTuple_GetItem(args, i);
    Py_INCREF(o);
    PyTuple_SET_ITEM(a, i+2, o);
  }

  slob = PyObject_Call((PyObject*)&Sblob_type, a, kwds);
  Py_DECREF(a);
  return slob;
}
#endif

static void cleanInputBinding(Cursor *cur)
{
  struct sqlda *da = &cur->daIn;
  if (da->sqlvar) {
    int i;
    for (i=0; i<da->sqld; i++) {
      /* may not actually exist in some err cases */
      if ( da->sqlvar[i].sqldata) {
        if (da->sqlvar[i].sqltype == CLOCATORTYPE) {
          loc_t *loc = (loc_t*) da->sqlvar[i].sqldata;
          if (loc->loc_buffer) {
            free(loc->loc_buffer);
          }
        }
#ifdef SQLUDTVAR
        if (da->sqlvar[i].sqltype == SQLUDTVAR) {
          ifx_var_dealloc((void**)&(da->sqlvar[i].sqldata));
        }
#endif
        free(da->sqlvar[i].sqldata);
      }
    }
  }
}

static void deleteInputBinding(Cursor *cur)
{
  cleanInputBinding(cur);
  if (cur->daIn.sqlvar) {
    free(cur->daIn.sqlvar);
    cur->daIn.sqlvar = 0;
    cur->daIn.sqld = 0;
  }
  if (cur->indIn) {
    free(cur->indIn);
    cur->indIn = 0;
  }
  if (cur->parmIdx) {
    free(cur->parmIdx);
    cur->parmIdx = 0;
  }
}

static void deleteOutputBinding(Cursor *cur)
{
  struct sqlda *da = cur->daOut;
  if (da && da->sqlvar) {
    int i;
    for (i=0; i<da->sqld; i++)
      if (da->sqlvar[i].sqldata &&
          (da->sqlvar[i].sqltype == CLOCATORTYPE)) {
        loc_t *loc = (loc_t*) da->sqlvar[i].sqldata;
        if (loc->loc_buffer)
          free(loc->loc_buffer);
      }
#ifdef HAVE_SBLOB
      if (ISSMARTBLOB(da->sqlvar[i].sqltype,da->sqlvar[i].sqlxid)) {
        free(da->sqlvar[i].sqldata);
      }
#endif
    free(cur->daOut);
    cur->daOut = 0;
  }
  if (cur->indOut) {
    free(cur->indOut);
    cur->indOut = 0;
  }
  if (cur->originalType) {
    free(cur->originalType);
    cur->originalType = 0;
  }
  if (cur->originalXid) {
    free(cur->originalXid);
    cur->originalXid = 0;
  }
  if (cur->outputBuffer) {
    free(cur->outputBuffer);
    cur->outputBuffer = 0;
  }

  Py_INCREF(Py_None);
  Py_DECREF(cur->description);
  cur->description = Py_None;
}

/* assumes that caller has already called setConnection */
static void doCloseCursor(Cursor *cur, int doFree)
{
  EXEC SQL BEGIN DECLARE SECTION;
  char *cursorName = cur->cursorName;
  char *queryName = cur->queryName;
  EXEC SQL END DECLARE SECTION;

  if (cur->stype == 0) {
    /* if cursor is opened, close it */
    if (cur->state == 3) {
      EXEC SQL CLOSE :cursorName;
      cur->state = 4;
    }

    if (doFree) {
      /* if cursor is prepared but not declared, free the statement */
      if (cur->state == 1)
        EXEC SQL FREE :queryName;

      /* if cursor is at least declared, free it */
      if (cur->state >= 2)
        EXEC SQL FREE :cursorName;

      cur->state = 0;
    }
  } else {
    if (doFree && cur->state == 1) {
      /* if statement is prepared, free it */
      EXEC SQL FREE :queryName;
      cur->state = 0;
    }
  }
}

static void Cursor_dealloc(Cursor *self)
{
  /* Make sure we talk to the right database. */
  if (self->conn) {
    if (setConnection(self->conn))
      PyErr_Clear();

    doCloseCursor(self, 1);
    deleteInputBinding(self);
    deleteOutputBinding(self);

    Py_XDECREF(self->conn);
    Py_XDECREF(self->messages);
    Py_XDECREF(self->errorhandler);

    free(self->cursorName);
  }

  self->ob_type->tp_free((PyObject*)self);
}

static PyObject *Cursor_close(Cursor *self)
{
  clear_messages(self);
  require_cursor_open(self);

  /* Make sure we talk to the right database. */
  if (setConnection(self->conn)) return NULL;

  /* per the spec, the cursor should not be useable after calling `close',
   * so go ahead and free the cursor */
  doCloseCursor(self, 1);

  Py_INCREF(Py_None);
  return Py_None;
}

static int
Cursor_init(Cursor *self, PyObject *args, PyObject *kwargs)
{
  Connection *conn;
  char *name = NULL;
  int rowformat = CURSOR_ROWFORMAT_TUPLE;

  static char* kwdlist[] = { "connection", "name", "rowformat", 0 };

  if (!PyArg_ParseTupleAndKeywords(args, kwargs, "O!|si", kwdlist,
                                   &Connection_type, &conn,
                                   &name, &rowformat))
    return -1;

  Py_INCREF(Py_None);
  self->description = Py_None;
  self->conn = conn;
  Py_INCREF(conn);
  self->state = 0;
  self->daIn.sqld = 0; self->daIn.sqlvar = 0;
  self->daOut = 0;
  self->originalType = 0;
  self->originalXid = 0;
  self->outputBuffer = 0;
  self->indIn = 0;
  self->indOut = 0;
  self->parmIdx = 0;
  self->stype = -1;
  self->op = 0;
  if (name) {
    self->cursorName = strdup(name);
  } else {
    self->cursorName = malloc(30); /* "some" */
    sprintf(self->cursorName, "CUR%p", self);
  }
  sprintf(self->queryName, "QRY%p", self);
  memset(self->sqlerrd, 0, sizeof(self->sqlerrd));
  self->rowcount = -1;
  self->arraysize = 1;
  self->messages = PyList_New(0);
  self->errorhandler = conn->errorhandler;
  Py_INCREF(self->errorhandler);
  if (rowformat == CURSOR_ROWFORMAT_DICT) {
    self->rowformat = CURSOR_ROWFORMAT_DICT;
  } else {
    self->rowformat = CURSOR_ROWFORMAT_TUPLE;
  }

  return 0;
}

static PyObject* Cursor_iter(Cursor *self)
{
  Py_INCREF(self);
  return (PyObject*)self;
}

static PyObject* Cursor_iternext(Cursor *self)
{
  PyObject *result = Cursor_fetchone(self);
  if (result == Py_None) {
    Py_DECREF(result);
    PyErr_SetNone(PyExc_StopIteration);
    return NULL;
  }
  return result;
}

static PyObject *Cursor_fetchone(Cursor *self)
{
  struct sqlda *tdaOut = self->daOut;
  int i;

  EXEC SQL BEGIN DECLARE SECTION;
  char *cursorName;
  EXEC SQL END DECLARE SECTION;

  cursorName = self->cursorName;

  require_cursor_open(self);

  /* Make sure we talk to the right database. */
  if (setConnection(self->conn))
    return NULL;

  Py_BEGIN_ALLOW_THREADS;
  EXEC SQL FETCH :cursorName USING DESCRIPTOR tdaOut;
  Py_END_ALLOW_THREADS;
  for (i=0; i<6; i++)
    self->sqlerrd[i] = sqlca.sqlerrd[i];
  if (!strncmp(SQLSTATE, "02", 2)) {
    Py_INCREF(Py_None);
    return Py_None;
  } else if (strncmp(SQLSTATE, "00", 2)) {
    ret_on_dberror_cursor(self, "FETCH");
  }
  return processOutput(self);
}

static PyObject *fetchCounted(Cursor *self, int count)
{
  PyObject *list = PyList_New(0);

  require_cursor_open(self);

  while ( count-- > 0 )
  {
      PyObject *entry = Cursor_fetchone(self);

      if ( entry == NULL )
      {
          Py_DECREF(list);
          return NULL;
      }
      if ( entry == Py_None )
      {
          Py_DECREF(entry);
          break;
      }

      if ( PyList_Append(list, entry) == -1 )
      {
          Py_DECREF(entry);
          Py_DECREF(list);
          return NULL;
      }

      Py_DECREF(entry);
  }

  return list;
}

static PyObject *Cursor_fetchmany(Cursor *self, PyObject *args, PyObject *kwds)
{
  int n_rows = self->arraysize;

  static char* kwdnames[] = { "size", NULL };

  if (!PyArg_ParseTupleAndKeywords(args, kwds, "|i", kwdnames, &n_rows))
      return NULL;

  return fetchCounted(self, n_rows);
}

static PyObject *Cursor_fetchall(Cursor *self)
{
  return fetchCounted(self, INT_MAX);
}

static PyObject *Cursor_setinputsizes(Cursor *self,
                                      PyObject *args,
                                      PyObject *kwds)
{
  clear_messages(self);
  require_cursor_open(self);

  Py_INCREF(Py_None);
  return Py_None;
}

static PyObject *Cursor_setoutputsize(Cursor *self,
                                      PyObject *args,
                                      PyObject *kwds)
{
  clear_messages(self);
  require_cursor_open(self);

  Py_INCREF(Py_None);
  return Py_None;
}

static PyObject *Cursor_callproc(Cursor *self, PyObject *args, PyObject *kwds)
{
  PyObject *params = 0, *exec_args, *ret = 0;
  char *func, *p_str = "";
  static char *kwd_list[] = { "procname", "parameters", 0 };

  clear_messages(self);
  require_cursor_open(self);

  if (!PyArg_ParseTupleAndKeywords(args, kwds, "s|O", kwd_list, &func, &params))
    return NULL;

  if (params) {
    int p_count, i;

    if (!PySequence_Check(params)) {
      PyErr_SetString(PyExc_TypeError, "SQL parameters are not a sequence");
      return NULL;
    }

    p_count = PySequence_Length(params);

    p_str = malloc(p_count * 2);

    /* this will build something like "?,?,?" */
    for (i = 0; i < p_count; ++i) {
      p_str[i*2] = '?';
      p_str[i*2+1] = ',';
    }
    p_str[p_count*2-1] = '\0';
  }

  exec_args = Py_BuildValue("(N)",
                  PyString_FromFormat("EXECUTE PROCEDURE %s(%s)",
                                      func, p_str));
  free(p_str);
  if (params) {
    _PyTuple_Resize(&exec_args, 2);
    Py_INCREF(params);
    PyTuple_SET_ITEM(exec_args, 1, params);
  }

  if (Cursor_execute(self, exec_args, NULL)) {
    if (!params)
      params = Py_None;
    Py_INCREF(params);
    ret = params;
  }
  Py_DECREF(exec_args);

  return ret;
}

static int Connection_init(Connection *self, PyObject *args, PyObject* kwds)
{
  EXEC SQL BEGIN DECLARE SECTION;
  char *connectionName = NULL;
  char *connectionString = NULL;
  char *dbUser = NULL;
  char *dbPass = NULL;
  EXEC SQL END DECLARE SECTION;

  static char* kwd_list[] = { "dsn", "user", "password", 0 };

  if (!PyArg_ParseTupleAndKeywords(args, kwds, "s|ss", kwd_list,
                                   &connectionString, &dbUser, &dbPass)) {
    return -1;
  }

  sprintf(self->name, "CONN%p", self);
  connectionName = self->name;
  self->is_open = 0;
  self->messages = PyList_New(0);
  self->errorhandler = Py_None;
  Py_INCREF(self->errorhandler);

  Py_BEGIN_ALLOW_THREADS;
  if (dbUser && dbPass) {
    EXEC SQL CONNECT TO :connectionString AS :connectionName USER :dbUser USING :dbPass WITH CONCURRENT TRANSACTION;
  } else {
    EXEC SQL CONNECT TO :connectionString AS :connectionName WITH CONCURRENT TRANSACTION;
  }
  Py_END_ALLOW_THREADS;

  if (is_dberror(self, NULL, "CONNECT")) {
    return -1;
  }

  self->is_open = 1;
  self->has_commit = (sqlca.sqlwarn.sqlwarn1 == 'W');

  if (self->has_commit) {
    EXEC SQL BEGIN WORK;
    if (is_dberror(self, NULL, "BEGIN")) {
      return -1;
    }
  }

  setConnectionName(self->name);

  return 0;
}

static PyObject* DatabaseError_init(PyObject* self, PyObject* args, PyObject* kwds)
{
  static char* kwdnames[] = { "self", "action", "sqlcode", "diagnostics", 0 }; 
  PyObject *action;
  PyObject *diags;
  long int sqlcode;

  if (!PyArg_ParseTupleAndKeywords(args, kwds, "OSlO!", kwdnames, &self,
                                   &action, &sqlcode, &PyList_Type, &diags)) {
    return NULL;
  }

  if (PyObject_SetAttrString(self, "action", action)) {
    return NULL;
  }

  if (PyObject_SetAttrString(self, "sqlcode", PyInt_FromLong(sqlcode))) {
    return NULL;
  }

  if (PyObject_SetAttrString(self, "diagnostics", diags)) {
    return NULL;
  }

  Py_INCREF(Py_None);
  return Py_None;
}

static PyObject* DatabaseError_str(PyObject* self, PyObject* args)
{
  PyObject *str, *action, *sqlcode, *diags, *a, *f;
  int i;
  self = PyTuple_GetItem(args, 0);

  action = PyObject_GetAttrString(self, "action");
  sqlcode = PyObject_GetAttrString(self, "sqlcode");
  diags = PyObject_GetAttrString(self, "diagnostics");

  a = Py_BuildValue("(NN)", sqlcode, action);
  f = PyString_FromString("SQLCODE %d in %s: \n");
  str = PyString_Format(f, a);
  Py_DECREF(f);
  Py_DECREF(a);

  f = PyString_FromString("%s: %s\n");

  for (i = 0; i < PyList_Size(diags); ++i) {
    PyObject* d = PyList_GetItem(diags, i);
    a = Py_BuildValue("(OO)", PyDict_GetItemString(d, "sqlstate"),
                              PyDict_GetItemString(d, "message"));
    PyString_ConcatAndDel(&str, PyString_Format(f, a));
    Py_DECREF(a);
  }

  Py_DECREF(f);

  return str;
}

static PyMethodDef DatabaseError_methods[] = {
  { "__init__", (PyCFunction)DatabaseError_init, METH_VARARGS|METH_KEYWORDS },
  { "__str__", (PyCFunction)DatabaseError_str, METH_VARARGS },
  { NULL }
};

static void setupdb_error(PyObject* exc)
{
  PyMethodDef* meth;

  for (meth = DatabaseError_methods; meth->ml_name != NULL; ++meth) {
    PyObject *func = PyCFunction_New(meth, NULL);
    PyObject *method = PyMethod_New(func, NULL, exc);
    PyObject_SetAttrString(exc, meth->ml_name, method);
    Py_DECREF(func);
    Py_DECREF(method);
  }
}

typedef struct {
  PyObject_HEAD
  PyObject *values;
} DBAPIType;

/* builds a tuple with which a DatabaseError can be created.
 *
 * returns a new reference.
 */
static PyObject* dberror_value(char *action)
{
  PyObject *list;
  EXEC SQL BEGIN DECLARE SECTION;
    int exc_count;
    char message[255];
    int messlen;
    char sqlstate[6];
    int i;
  EXEC SQL END DECLARE SECTION;

  list = PyList_New(0);
  if (!list)
    return NULL;

  EXEC SQL get diagnostics :exc_count = NUMBER;

  for (i = 1; i <= exc_count; ++i) {
    PyObject* msg;
    EXEC SQL get diagnostics exception :i :sqlstate = RETURNED_SQLSTATE,
               :message = MESSAGE_TEXT, :messlen = MESSAGE_LENGTH;
    if (!message || messlen < 0 || messlen > sizeof(message)) {
      /* skip on invalid message */
      break;
    }
    /* recalculate messlen, since it's sometimes wrong (or at least
       some old comment said so...) */
    messlen = byleng(message, sizeof(message)-1);
    message[messlen] = '\0';

    msg = Py_BuildValue("{ssss}", "sqlstate", sqlstate, "message", message);
    PyList_Append(list, msg);
    Py_DECREF(msg);
  }

  return Py_BuildValue("(siN)", action, SQLCODE, list);
}

/* determines the type of an error by looking at SQLSTATE */
static PyObject* dberror_type(PyObject *override)
{
  if (override) {
    return override;
  }

  switch (SQLSTATE[0]) {
  case '0':
    switch (SQLSTATE[1]) {
    case '1': /* 01xxx Success with warning */
      return ExcWarning;
    case '2': /* 02xxx No data found or End of data reached */
      break;
    case '7': /* 07xxx Dynamic SQL error */
      return ExcProgrammingError;
    case '8': /* 08xxx Connection exception */
      return ExcOperationalError;
    case 'A': /* 0Axxx Feature not supported */
      return ExcNotSupportedError;
    }
    break;
  case '2':
    switch (SQLSTATE[1]) {
    case '1': /* 21xxx Cardinality violation */
      return ExcProgrammingError;
    case '2': /* 22xxx Data error */
      return ExcDataError;
    case '3': /* 23000 Integrity-constraint violation */
      return ExcIntegrityError;
    case '4': /* 24000 Invalid cursor state */
    case '5': /* 25000 Invalid transaction state */
    case 'B': /* 2B000 Dependent priviledge descriptor still exists */
    case 'D': /* 2D000 Invalid transaction termination */
      return ExcInternalError;
    case '6': /* 26000 Invalid SQL statement identifier */
    case 'E': /* 2E000 Invalid connection name */
    case '8': /* 28000 Invalid user-authorization specification */
      return ExcOperationalError;
    }
    break;
  case '3':
    switch (SQLSTATE[1]) {
    case '3': /* 33000 Invalid SQL descriptor name */
    case '4': /* 34000 Invalid cursor name */
    case '5': /* 35000 Invalid exception number */
      return ExcOperationalError;
    case '7': /* 37000 Syntax error or acces violation in ... */
      return ExcProgrammingError;
    case 'C': /* 3C000 Duplicate cursor name */
      return ExcOperationalError;
    }
    break;
  case '4':
    switch (SQLSTATE[1]) {
    case '0': /* 40000 Transaction rollback */
              /* 40003 Statement completion unknown */
      return ExcOperationalError;
    case '2': /* 42000 Syntax error or access violation */
      return ExcProgrammingError;
    }
    break;
  case 'S':
    switch (SQLSTATE[1]) {
    case '0': /* S0xxx Invalid name */
      return ExcProgrammingError;
    case '1': /* S1000 Memory-allocation error message */
      return ExcOperationalError;
    }
    break;
  }

  return ExcDatabaseError;
}

/*
 * steals a reference to value, but not to type!
 * returns 0 ... go on; 1 ... exception raised
 */
static int error_handle(Connection *connection, Cursor *cursor,
                        PyObject *type, PyObject *value)
{
  PyObject *handler=NULL;

  if (cursor && cursor->errorhandler != Py_None) {
    handler = cursor->errorhandler;
  } else if (!cursor && connection && connection->errorhandler != Py_None) {
    handler = connection->errorhandler;
  }

  if (handler) {
    PyObject *args, *hret;

    args = Py_BuildValue("(OOON)", (PyObject*)connection,
                         cursor ? (PyObject*)cursor : Py_None, type, value);
    hret = PyObject_Call(handler, args, NULL);
    Py_DECREF(args);
    if (hret) {
      Py_DECREF(hret);
      return 0;
    } else {
      return 1;
    }
  } else {
    PyObject *msg;
    msg = Py_BuildValue("(ON)", type, value);

    if (cursor) {
      PyList_Append(cursor->messages, msg);
    } else if (connection) {
      PyList_Append(connection->messages, msg);
    }

    if (type != ExcWarning) {
      PyErr_SetObject(type, value);
      Py_DECREF(msg);
      return 1;
    } else {
      Py_DECREF(msg);
      return 0;
    }
  }
}

static int
DBAPIType_init(DBAPIType *self, PyObject *args, PyObject *kwargs)
{
  if (!PyArg_ParseTuple(args, "O!", &PyList_Type, &self->values))
    return -1;

  Py_INCREF(self->values);
  return 0;
}

PyObject*
DBAPIType_richcompare(DBAPIType* self, PyObject* other, int opid)
{
  if (opid == Py_EQ || opid == Py_NE) {
    int r = PySequence_Contains(self->values, other);
    if (r == -1) /* error occured */
      return PyInt_FromLong(-1);

    return PyInt_FromLong(opid == Py_EQ ? r == 1 : r == 0);
  }
  return PyObject_RichCompare(self->values, other, opid);
}

PyObject*
DBAPIType_repr(DBAPIType* self)
{
  PyObject *s,*val;
  char *str;

  val = self->values->ob_type->tp_repr(self->values);
  if (!val)
    return NULL;
  str = PyString_AsString(val);

  s = PyString_FromFormat("DBAPIType(%s)", str);
  Py_DECREF(val);
  return s;
}

PyObject*
DBAPIType_str(DBAPIType* self)
{
  return self->values->ob_type->tp_repr(self->values);
}

PyDoc_STRVAR(DBAPIType_doc,
"Helper for comparison with database type names.\n\n\
Objects of this class will compare equal to a list of database types.\n\
This is the preferred method to check for a given type in a Cursor's\n\
description. E.g.:\n\n\
>>> informixdb.STRING == 'char'\n\
1\n\
>>> informixdb.STRING == 'integer'\n\
0\n\
>>> cursor.description[0]\n\
('first', 'char', 25, 25, None, None, 1)\n\
>>> cursor.description[0][1] == informixdb.STRING\n\
1");

static PyTypeObject DBAPIType_type = {
  PyObject_HEAD_INIT(DEFERRED_ADDRESS(&PyType_Type))
  0,                                  /* ob_size*/
  "_informixdb.DBAPIType",            /* tp_name */
  sizeof(DBAPIType),                  /* tp_basicsize */
  0,                                  /* tp_itemsize */
  0,                                  /* tp_dealloc */
  0,                                  /* tp_print */
  0,                                  /* tp_getattr */
  0,                                  /* tp_setattr */
  0,                                  /* tp_compare */
  (reprfunc)DBAPIType_repr,           /* tp_repr */
  0,                                  /* tp_as_number */
  0,                                  /* tp_as_sequence */
  0,                                  /* tp_as_mapping */
  0,                                  /* tp_hash */
  0,                                  /* tp_call */
  (reprfunc)DBAPIType_str,            /* tp_str */
  0,                                  /* tp_getattro */
  0,                                  /* tp_setattro */
  0,                                  /* tp_as_buffer */
  Py_TPFLAGS_DEFAULT,                 /* tp_flags */
  DBAPIType_doc,                      /* tp_doc */
  0,                                  /* tp_traverse */
  0,                                  /* tp_clear */
  (PyObject*(*)(PyObject*,PyObject*,int)) DBAPIType_richcompare, /* tp_richcompare */
  0,                                  /* tp_weaklistoffset */
  0,                                  /* tp_iter */
  0,                                  /* tp_iternext */
  0,                                  /* tp_methods */
  0,                                  /* tp_members */
  0,                                  /* tp_getset */
  0,                                  /* tp_base */
  0,                                  /* tp_dict */
  0,                                  /* tp_descr_get */
  0,                                  /* tp_descr_set */
  0,                                  /* tp_dictoffset */
  (initproc)DBAPIType_init,           /* tp_init */
  PyType_GenericAlloc,                /* tp_alloc */
  PyType_GenericNew,                  /* tp_new */
  _PyObject_Del                       /* tp_free */
};

static PyObject* dbtp_create(char* types[])
{
  char** tp;
  PyObject *dbtp, *l, *a, *s;
  l = PyList_New(0);
  for (tp = types; *tp != NULL; ++tp) {
    s = PyString_FromString(*tp);
    PyList_Append(l, s);
    Py_DECREF(s);
  }
  a = Py_BuildValue("(N)", l);
  dbtp = PyObject_Call((PyObject*)&DBAPIType_type, a, NULL);
  Py_DECREF(a);
  return dbtp;
}

static PyObject* db_Date(PyObject *self, PyObject *args, PyObject *kwds)
{
  return PyObject_Call((PyObject*)PyDateTimeAPI->DateType, args, kwds);
}

static PyObject* db_Time(PyObject *self, PyObject *args, PyObject *kwds)
{
  int hour=0, minute=0, second=0, usec=0;

  static char* kwdnames[] = { "hour", "minute", "second", "microsecond", NULL };
  if (!PyArg_ParseTupleAndKeywords(args, kwds, "iii|i", kwdnames,
                                   &hour, &minute, &second, &usec)) {
    return NULL;
  }

  /* 0 isn't allowed as value for year/month/day */
  return PyDateTime_FromDateAndTime(1,1,1,hour,minute,second,usec);
}

static PyObject* db_Timestamp(PyObject *self, PyObject *args, PyObject *kwds)
{
  return PyObject_Call((PyObject*)PyDateTimeAPI->DateTimeType, args, kwds);
}

static PyObject* db_DateFromTicks(PyObject *self, PyObject *args)
{
  return PyDate_FromTimestamp(args);
}

static PyObject* db_TimestampFromTicks(PyObject *self, PyObject *args)
{
  return PyDateTime_FromTimestamp(args);
}

static PyObject* db_Binary(PyObject *self, PyObject *args, PyObject *kwds)
{
  PyObject *s;

  static char* kwdnames[] = { "string", NULL };
  if (!PyArg_ParseTupleAndKeywords(args, kwds, "S", kwdnames, &s)) {
    return NULL;
  }

  return PyBuffer_FromObject(s, 0, Py_END_OF_BUFFER);
}

static PyObject* db_connect(PyObject *self, PyObject *args, PyObject *kwds)
{
  return PyObject_Call((PyObject*)&Connection_type, args, kwds);
}

PyDoc_STRVAR(db_connect_doc,
"connect(dsn[,user,password]) -> Connection\n\n\
Establish a connection to a database.\n\n\
'dsn' identifies a database environment as accepted by the CONNECT\n\
statement. It can be the name of a database ('stores7'), the name\n\
of a database server ('@valley'), or a combination thereof\n\
('stores7@valley').");

PyDoc_STRVAR(db_Date_doc,
"Date(year,month,day) -> datetime.date\n\n\
Construct an object holding a date value.");

PyDoc_STRVAR(db_Time_doc,
"Time(hour,minute,second[,microsecond=0]) -> datetime.datetime\n\n\
Construct an object holding a time value.\n\n\
Note: 'microsecond' is an extension to the DB-API specification. It\n\
      represents the fractional part of an Informix DATETIME column,\n\
      and is therefore limited to a maximum of 10 microseconds of\n\
      accuracy.");

PyDoc_STRVAR(db_Timestamp_doc,
"Timestamp(year,month,day,hour=0,minute=0,second=0,microsecond=0)\n\
  -> datetime.datetime\n\n\
Construct an object holding a time stamp (datetime) value.\n\n\
Note: 'microsecond' is an extension to the DB-API specification. It\n\
      represents the fractional part of an Informix DATETIME column,\n\
      and is therefore limited to a maximum of 10 microseconds of\n\
      accuracy.");

PyDoc_STRVAR(db_TimestampFromTicks_doc,
"TimestampFromTicks(ticks) -> datetime.datetime\n\n\
Construct an object holding a time stamp (datetime) from the given\n\
ticks value.\n\n\
'ticks' are the number of seconds since the start of the current epoch.");

PyDoc_STRVAR(db_DateFromTicks_doc,
"DateFromTicks(ticks) -> datetime.date\n\n\
Construct an object holding a date value from the given ticks value.\n\n\
'ticks' are the number of seconds since the start of the current epoch.");

PyDoc_STRVAR(db_TimeFromTicks_doc,
"TimeFromTicks(ticks) -> datetime.datetime\n\n\
Construct an object holding a time value from the given ticks value.\n\n\
'ticks' are the number of seconds since the start of the current epoch.");

PyDoc_STRVAR(db_Binary_doc,
"Binary(string) -> buffer\n\n\
Construct an object capable of holding a BYTE or TEXT value.");

static PyMethodDef globalMethods[] = {
  { "connect", (PyCFunction)db_connect, METH_VARARGS|METH_KEYWORDS,
    db_connect_doc } ,
  { "Date", (PyCFunction)db_Date, METH_VARARGS|METH_KEYWORDS,
    db_Date_doc },
  { "Time", (PyCFunction)db_Time, METH_VARARGS|METH_KEYWORDS,
    db_Time_doc },
  { "Timestamp", (PyCFunction)db_Timestamp, METH_VARARGS|METH_KEYWORDS,
    db_Timestamp_doc },
  { "TimestampFromTicks", (PyCFunction)db_TimestampFromTicks, METH_VARARGS,
    db_TimestampFromTicks_doc },
  { "DateFromTicks", (PyCFunction)db_DateFromTicks, METH_VARARGS,
    db_DateFromTicks_doc },
  { "TimeFromTicks", (PyCFunction)db_TimestampFromTicks, METH_VARARGS,
    db_TimeFromTicks_doc },
  { "Binary", (PyCFunction)db_Binary, METH_VARARGS|METH_KEYWORDS,
    db_Binary_doc},
  { NULL }
};

#ifdef HAVE_SBLOB
static int Sblob_init(Sblob *self, PyObject *args, PyObject* kwargs)
{
  struct Connection_t *conn;
  int do_create = 0;
  mint create_flags = 0;
  mint open_flags = LO_RDWR;
  int sblob_type = 0;
  static char* kwdlist[] = {
    "connection", "do_create", "type", "create_flags", "open_flags", 0
  };
  mint result, err;

  if (!PyArg_ParseTupleAndKeywords(
         args, kwargs, "O!i|iii", kwdlist, &Connection_type, &conn,
         &do_create, &sblob_type, &create_flags, &open_flags))
    return -1;

  self->conn = conn;
  Py_INCREF(conn);

  self->lofd = 0;
  self->lo_spec = NULL;
  self->sblob_type = sblob_type;
  if (do_create) {
    if (setConnection(self->conn)) return -1;
    result = ifx_lo_def_create_spec(&self->lo_spec);
    if (result<0) {
      is_dberror(self->conn, NULL, "ifx_lo_def_create_spec");
      return -1;
    }
    result = ifx_lo_specset_flags(self->lo_spec, create_flags);
    if (result<0) {
      is_dberror(self->conn, NULL, "ifx_lo_specset_flags");
      return -1;
    }
    result = ifx_lo_create(self->lo_spec, open_flags, &self->lo, &err);
    if (result<0) {
      is_dberror(self->conn, NULL, "ifx_lo_create");
      return -1;
    }
    self->lofd = result;
  }
  return 0;
}

static void Sblob_dealloc(Sblob *self)
{
  if (self->lofd) {
    ifx_lo_close(self->lofd);
    self->lofd = 0;
  }
  if (self->lo_spec) {
    ifx_lo_spec_free(self->lo_spec);
    self->lo_spec = NULL;
  }
  self->ob_type->tp_free((PyObject*)self);
}

static PyObject *Sblob_close(Sblob *self) {
  if (self->lofd) {
    if (setConnection(self->conn)) return NULL;
    ifx_lo_close(self->lofd);
    self->lofd = 0;
  }
  Py_INCREF(Py_None);
  return Py_None;
}

static PyObject *Sblob_open(Sblob *self, PyObject *args, PyObject *kwargs)
{
  mint flags = 0;
  static char* kwdlist[] = { "flags", 0 };
  mint result, err;

  if (self->lofd) {
    if (error_handle(self->conn, NULL, ExcInterfaceError,
        PyString_FromString("Sblob is already open")))
      return NULL;
  }
  if (!PyArg_ParseTupleAndKeywords(args, kwargs, "|i", kwdlist, &flags))
    return NULL;
  if (setConnection(self->conn)) return NULL;
  result = ifx_lo_open(&self->lo, flags, &err);
  if (result<0) {
    ret_on_dberror(self->conn, NULL, "ifx_lo_open");
  }
  self->lofd = result;
  Py_INCREF(Py_None);
  return Py_None;
}

static PyObject *Sblob_read(Sblob *self, PyObject *args, PyObject *kwargs)
{
  static char* kwdlist[] = { "nbytes", 0 };
  mint result, err;
  char *buf;
  PyObject *py_result;
  mint buflen;
  if (!self->lofd) {
    if (error_handle(self->conn, NULL, ExcInterfaceError,
        PyString_FromString("Sblob is not open")))
      return NULL;
  }
  if (!PyArg_ParseTupleAndKeywords(args, kwargs, "i", kwdlist, &buflen))
    return NULL;
  buf = PyMem_Malloc(buflen);
  if (!buf) {
    return PyErr_NoMemory();
  }
  if (setConnection(self->conn)) return NULL;
  result = ifx_lo_read(self->lofd, buf, buflen, &err);
  if (result<0) {
    PyMem_Free(buf);
    ret_on_dberror(self->conn, NULL, "ifx_lo_read");
  }
  py_result = PyString_FromStringAndSize(buf, result);
  PyMem_Free(buf);
  return py_result;
}

static PyObject *Sblob_write(Sblob *self, PyObject *args, PyObject *kwargs)
{
  static char* kwdlist[] = { "buf", 0 };
  mint result, err;
  char *buf;
  mint buflen;
  if (!self->lofd) {
    if (error_handle(self->conn, NULL, ExcInterfaceError,
        PyString_FromString("Sblob is not open")))
      return NULL;
  }
  if (!PyArg_ParseTupleAndKeywords(args, kwargs, "s#", kwdlist, &buf, &buflen))
    return NULL;
  if (setConnection(self->conn)) return NULL;
  result = ifx_lo_write(self->lofd, buf, buflen, &err);
  if (result<0) {
    ret_on_dberror(self->conn, NULL, "ifx_lo_write");
  }
  return PyInt_FromLong((long)result);
}

static PyObject *Sblob_seek(Sblob *self, PyObject *args, PyObject *kwargs)
{
  static char* kwdlist[] = { "offset", "whence", 0 };
  mint result;
  PyObject *py_offset;
  PyObject *sitem;
  char *val, pos_str[30];
  mint whence = LO_SEEK_SET;
  ifx_int8_t offset, seek_pos;

  if (!self->lofd) {
    if (error_handle(self->conn, NULL, ExcInterfaceError,
        PyString_FromString("Sblob is not open")))
      return NULL;
  }
  if (!PyArg_ParseTupleAndKeywords(args, kwargs, "O|i", kwdlist,
                                   &py_offset, &whence))
    return NULL;
  
  sitem = PyObject_Str(py_offset);
  val = PyString_AS_STRING((PyStringObject*)sitem);
  result = ifx_int8cvasc(val, strlen(val), &offset);
  Py_DECREF(sitem);
  if (result<0) {
    ret_on_dberror(self->conn, NULL, "ifx_int8cvasc");
  }
  if (setConnection(self->conn)) return NULL;
  if (ifx_lo_seek(self->lofd, &offset, whence, &seek_pos)<0) {
    ret_on_dberror(self->conn, NULL, "ifx_lo_seek");
  }
  if (ifx_int8toasc(&seek_pos, pos_str, 29)<0) {
    ret_on_dberror(self->conn, NULL, "ifx_int8toasc");
  }
  pos_str[29] = 0; 
  return PyLong_FromString(pos_str, NULL, 10);
}

static PyObject *Sblob_tell(Sblob *self)
{
  ifx_int8_t seek_pos;
  char pos_str[30];

  if (!self->lofd) {
    if (error_handle(self->conn, NULL, ExcInterfaceError,
        PyString_FromString("Sblob is not open")))
      return NULL;
  }
  if (setConnection(self->conn)) return NULL;
  if (ifx_lo_tell(self->lofd, &seek_pos)<0) {
    ret_on_dberror(self->conn, NULL, "ifx_lo_tell");
  }
  if (ifx_int8toasc(&seek_pos, pos_str, 29)<0) {
    ret_on_dberror(self->conn, NULL, "ifx_int8toasc");
  }
  pos_str[29] = 0; 
  return PyLong_FromString(pos_str, NULL, 10);
}

static PyObject *maketimestamp(int ticks)
{
  PyObject *a, *result;
  a = Py_BuildValue("(i)",ticks);
  result = db_TimestampFromTicks(NULL,a);
  Py_DECREF(a);
  return result;
}

static PyObject *Sblob_stat(Sblob *self)
{
  ifx_lo_stat_t *lo_stat;
  ifx_int8_t stat_size;
  char size_str[30];
  PyObject *size_result;
  mint atime, ctime, mtime, refcnt;
  PyObject *atime_result, *ctime_result, *mtime_result;

  if (!self->lofd) {
    if (error_handle(self->conn, NULL, ExcInterfaceError,
        PyString_FromString("Sblob is not open")))
      return NULL;
  }
  if (setConnection(self->conn)) return NULL;
  if (ifx_lo_stat(self->lofd, &lo_stat)<0) {
    ret_on_dberror(self->conn, NULL, "ifx_lo_stat");
  }
  if (ifx_lo_stat_size(lo_stat, &stat_size)<0) {
    ret_on_dberror(self->conn, NULL, "ifx_lo_stat_size");
  }
  atime=ifx_lo_stat_atime(lo_stat);
  ctime=ifx_lo_stat_ctime(lo_stat);
  mtime=ifx_lo_stat_mtime_sec(lo_stat);
  if ((refcnt=ifx_lo_stat_refcnt(lo_stat))<0) {
    refcnt = 0;
  }
  if (ifx_lo_stat_free(lo_stat)<0) {
    ret_on_dberror(self->conn, NULL, "ifx_lo_stat_free");
  }
  if (ifx_int8toasc(&stat_size, size_str, 29)<0) {
    ret_on_dberror(self->conn, NULL, "ifx_int8toasc");
  }
  if (atime<0) {
    atime_result = Py_None; Py_INCREF(Py_None);
  } else {
    atime_result = maketimestamp(atime);
  }
  if (ctime<0) {
    ctime_result = Py_None; Py_INCREF(Py_None);
  } else {
    ctime_result = maketimestamp(ctime);
  }
  if (mtime<0) {
    mtime_result = Py_None; Py_INCREF(Py_None);
  } else {
    mtime_result = maketimestamp(mtime);
  }
  size_str[29] = 0; 
  size_result = PyLong_FromString(size_str, NULL, 10);
  return Py_BuildValue("{sNsNsNsNsi}", "size", size_result,
    "atime", atime_result, "ctime", ctime_result,
    "mtime", mtime_result, "refcnt", refcnt);
}
#endif

PyDoc_STRVAR(_informixdb_doc,
"DB-API 2.0 compliant interface for Informix databases.\n");

void init_informixdb(void)
{
  int threadsafety = 0;

  /* define how sql types should be mapped to dbapi 2.0 types */
  static char* dbtp_string[] = { "char", "varchar", "nchar",
                                 "nvarchar", "lvarchar", NULL };
  static char* dbtp_binary[] = { "byte", "text", NULL };
  static char* dbtp_number[] = { "smallint", "integer", "int8", "float",
                                 "smallfloat", "decimal", "money", NULL };
  static char* dbtp_datetime[] = { "date", "datetime", NULL };
  static char* dbtp_rowid[] = { "serial", "serial8", NULL };

  PyObject *m = Py_InitModule3("_informixdb", globalMethods, _informixdb_doc);
  PyObject *informixdbmodule;
  PyObject *informixdbmdict;

#define defException(name, base) \
          do { \
            PyObject* d = Py_BuildValue("{sssssisN}", "__doc__", Exc##name##_doc,\
                                        "action", "", "sqlcode", 0,\
                                        "diagnostics", PyList_New(0)); \
            Exc##name = PyErr_NewException("_informixdb."#name, base, d); \
            Py_DECREF(d); \
            PyModule_AddObject(m, #name, Exc##name); \
          } while(0);
  defException(Warning, PyExc_StandardError);
  setupdb_error(ExcWarning);
  defException(Error, PyExc_StandardError);
  defException(InterfaceError, ExcError);
  defException(DatabaseError, ExcError);
  setupdb_error(ExcDatabaseError);
  defException(InternalError, ExcDatabaseError);
  defException(OperationalError, ExcDatabaseError);
  defException(ProgrammingError, ExcDatabaseError);
  defException(IntegrityError, ExcDatabaseError);
  defException(DataError, ExcDatabaseError);
  defException(NotSupportedError, ExcDatabaseError);
#undef defException

  Cursor_type.ob_type = &PyType_Type;
  Connection_type.ob_type = &PyType_Type;
  DBAPIType_type.ob_type = &PyType_Type;

  Connection_getseters[0].closure = ExcWarning;
  Connection_getseters[1].closure = ExcError;
  Connection_getseters[2].closure = ExcInterfaceError;
  Connection_getseters[3].closure = ExcDatabaseError;
  Connection_getseters[4].closure = ExcInternalError;
  Connection_getseters[5].closure = ExcOperationalError;
  Connection_getseters[6].closure = ExcProgrammingError;
  Connection_getseters[7].closure = ExcIntegrityError;
  Connection_getseters[8].closure = ExcDataError;
  Connection_getseters[9].closure = ExcNotSupportedError;

  PyType_Ready(&Cursor_type);
  PyType_Ready(&Connection_type);
  PyType_Ready(&DBAPIType_type);

#ifdef HAVE_SBLOB
  Sblob_type.ob_type = &PyType_Type;
  PyType_Ready(&Sblob_type);
  Py_INCREF(&Sblob_type);
#endif

#ifdef IFX_THREAD
  threadsafety = 1;
#endif

  PyModule_AddIntConstant(m, "threadsafety", threadsafety);
  PyModule_AddStringConstant(m, "apilevel", "2.0");
  PyModule_AddStringConstant(m, "paramstyle", "numeric");
  PyModule_AddStringConstant(m, "__docformat__", "restructuredtext en");

  PyModule_AddObject(m, "STRING", dbtp_create(dbtp_string));
  PyModule_AddObject(m, "BINARY", dbtp_create(dbtp_binary));
  PyModule_AddObject(m, "NUMBER", dbtp_create(dbtp_number));
  PyModule_AddObject(m, "DATETIME", dbtp_create(dbtp_datetime));
  PyModule_AddObject(m, "ROWID", dbtp_create(dbtp_rowid));

  PyModule_AddIntConstant(m, "ROW_AS_TUPLE", CURSOR_ROWFORMAT_TUPLE);
  PyModule_AddIntConstant(m, "ROW_AS_DICT", CURSOR_ROWFORMAT_DICT);

#ifdef HAVE_SBLOB
#define ExposeIntConstant(x) PyModule_AddIntConstant(m, #x, x)
  ExposeIntConstant(SBLOB_TYPE_BLOB);
  ExposeIntConstant(SBLOB_TYPE_CLOB);
  ExposeIntConstant(LO_OPEN_APPEND);
  ExposeIntConstant(LO_OPEN_WRONLY);
  ExposeIntConstant(LO_OPEN_RDONLY);
  ExposeIntConstant(LO_OPEN_RDWR);
  ExposeIntConstant(LO_OPEN_DIRTY_READ);
  ExposeIntConstant(LO_OPEN_RANDOM);
  ExposeIntConstant(LO_OPEN_SEQUENTIAL);
  ExposeIntConstant(LO_OPEN_FORWARD);
  ExposeIntConstant(LO_OPEN_REVERSE);
  ExposeIntConstant(LO_OPEN_BUFFER);
  ExposeIntConstant(LO_OPEN_NOBUFFER);
  ExposeIntConstant(LO_OPEN_NODIRTY_READ);
  ExposeIntConstant(LO_OPEN_LOCKALL);
  ExposeIntConstant(LO_OPEN_LOCKRANGE);
  ExposeIntConstant(LO_ATTR_LOG);
  ExposeIntConstant(LO_ATTR_NOLOG);
  ExposeIntConstant(LO_ATTR_DELAY_LOG);
  ExposeIntConstant(LO_ATTR_KEEP_LASTACCESS_TIME);
  ExposeIntConstant(LO_ATTR_NOKEEP_LASTACCESS_TIME);
  ExposeIntConstant(LO_ATTR_HIGH_INTEG);
  ExposeIntConstant(LO_ATTR_MODERATE_INTEG);
  ExposeIntConstant(LO_ATTR_TEMP);
  ExposeIntConstant(LO_SEEK_SET);
  ExposeIntConstant(LO_SEEK_CUR);
  ExposeIntConstant(LO_SEEK_END);
#endif

  Py_INCREF(&Connection_type);
  PyModule_AddObject(m, "Connection", (PyObject*)&Connection_type);
  Py_INCREF(&Cursor_type);
  PyModule_AddObject(m, "Cursor", (PyObject*)&Cursor_type);

  /* obtain the type objects for the Interval classes */
  informixdbmodule = PyImport_ImportModule("informixdb");
  informixdbmdict = PyModule_GetDict(informixdbmodule);
  IntervalY2MType = PyDict_GetItemString(
                      informixdbmdict, "IntervalYearToMonth");
  IntervalD2FType = PyDict_GetItemString(
                      informixdbmdict, "IntervalDayToFraction");
  Py_INCREF(IntervalY2MType);
  Py_INCREF(IntervalD2FType);

  PyDateTime_IMPORT;

  /* when using a connection mode with forking (i.e. Informix SE)
     child processes might stay around as <defunct> unless SIGCHLD
     is handled */
  sqlsignal(-1, (void*)NULL, 0); 
}
