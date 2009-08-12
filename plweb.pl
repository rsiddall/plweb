/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2009, VU University Amsterdam

    This program is free software; you can redistribute it and/or
    modify it under the terms of the GNU General Public License
    as published by the Free Software Foundation; either version 2
    of the License, or (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public
    License along with this library; if not, write to the Free Software
    Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

    As a special exception, if you link this library with other files,
    compiled with a Free Software compiler, to produce an executable, this
    library does not by itself cause the resulting executable to be covered
    by the GNU General Public License. This exception does not however
    invalidate any other reasons why the executable file might be covered by
    the GNU General Public License.
*/

:- module(plweb,
	  [ server/0
	  ]).
:- use_module(limit).

:- use_module(library(pldoc)).
:- use_module(library(pldoc/doc_wiki)).
:- use_module(library(pldoc/doc_man)).
:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_path)).
:- use_module(library(http/html_write)).
:- use_module(library(http/html_head)).
:- use_module(library(http/mimetype)).
:- use_module(library(http/http_error)).
:- use_module(library(settings)).
:- use_module(library(error)).
:- use_module(library(debug)).
:- use_module(library(apply)).
:- use_module(library(readutil)).
:- use_module(library(lists)).
:- use_module(library(occurs)).
:- use_module(library(pairs)).
:- use_module(library(thread_pool)).

:- use_module(parms).
:- use_module(page).
:- use_module(download).
:- use_module(wiki).
:- use_module(http_cgi).
:- use_module(gitweb).
:- use_module(update).
:- use_module(http_dirindex).
:- use_module(autocomplete).
:- use_module(customise).

:- http_handler(root(.),	     serve_page,  [prefix, priority(10), spawn(wiki)]).
:- http_handler(root('favicon.ico'), favicon,	  [priority(10)]).
:- http_handler(root(man),	     manual_file, [prefix, priority(10), spawn(wiki)]).

/** <module> Server for PlDoc wiki pages and SWI-Prolog website

@tbd	Turn directory listing into a library.
*/

		 /*******************************
		 *            SERVER		*
		 *******************************/

server :-
	init_thread_pools,
	setting(http:port, Port),
	setting(http:workers, Workers),
	server([ port(Port),
		 workers(Workers)
	       ]).

server(Options) :-
	http_server(http_dispatch, Options).


%%	favicon(+Request)
%
%	Serve /favicon.ico.

favicon(Request) :-
	http_reply_file(icons('favicon.ico'), [], Request).


		 /*******************************
		 *	      SERVICES		*
		 *******************************/

%%	serve_page(+Request)
%
%	HTTP handler for files below document-root.

serve_page(Request) :-
	memberchk(path_info(Relative), Request),
	find_file(Relative, File), !,
	absolute_file_name(document_root(.), DocRoot),
	(   atom_concat(DocRoot, _, File)
	->  serve_file(File, Request)
	;   memberchk(path(Path), Request),
	    permission_error(access, http_location, Path)
	).
serve_page(Request) :-
	\+ memberchk(path_info(_), Request), !,
	serve_page([path_info('index.html')|Request]).
serve_page(Request) :-
	memberchk(path(Path), Request),
	existence_error(http_location, Path).

%%	find_file(+Relative, -File) is det.
%
%	Translate Relative into a File in the document-root tree. If the
%	given extension is .html, also look for   .txt files that can be
%	translated into HTML.

find_file(Relative, File) :-
	file_name_extension(Base, html, Relative),
	file_name_extension(Base, txt, WikiFile),
	absolute_file_name(document_root(WikiFile),
			   File,
			   [ access(read),
			     file_errors(fail)
			   ]), !.
find_file(Relative, File) :-
	absolute_file_name(document_root(Relative),
			   File,
			   [ access(read),
			     file_errors(fail)
			   ]).


%%	serve_file(+File, +Request) is det.
%%	serve_file(+Extension, +File, +Request) is det.
%
%	Serve the requested file.

serve_file(File, Request) :-
	file_name_extension(_, Ext, File),
	debug(plweb, 'Serving ~q; ext=~q', [File, Ext]),
	serve_file(Ext, File, Request).

serve_file('',  Dir, Request) :-
	exists_directory(Dir), !,
	(   sub_atom(Dir, _, _, 0, /),
	    serve_index_file(Dir, Request)
	->  true
	;   http_dirindex(Request, Dir)
	).
serve_file(txt, File, _Request) :- !,
	read_file_to_codes(File, String, []),
	b_setval(pldoc_file, File),
	call_cleanup(serve_wike(String),
		     nb_delete(pldoc_file)).
serve_file(_Ext, File, Request) :-	% serve plain files
	http_reply_file(File, [unsafe(true)], Request).

%%	serve_index_file(+Dir, +Request) is semidet.
%
%	Serve index.txt or index.html, etc. if it exists.

serve_index_file(Dir, Request) :-
        setting(http:index_files, Indices),
        member(Index, Indices),
	ensure_slash(Dir, DirSlash),
	atom_concat(DirSlash, Index, File),
        access_file(File, read), !,
        serve_file(File, Request).

ensure_slash(Dir, Dir) :-
	sub_atom(Dir, _, _, 0, /), !.
ensure_slash(Dir0, Dir) :-
	atom_concat(Dir0, /, Dir).


%%	serve_wiki(+String) is det.
%
%	Emit page from wiki content in String.

serve_wike(String) :-
	wiki_codes_to_dom(String, [], DOM),
	(   sub_term(h1(_, Title), DOM)
	->  true
	;   Title = 'SWI-Prolog'
	),
	reply_html_page([ title(Title)
			],
			DOM).

%%	manual_file(+Request) is det.
%
%	HTTP handler for /man/file.html

manual_file(Request) :-
	memberchk(path_info(Relative), Request),
	atom_concat('doc/Manual', Relative, Man),
	absolute_file_name(swi(Man),
			   ManFile,
			   [ access(read),
			     file_errors(fail)
			   ]), !,
	reply_html_page(title('SWI-Prolog manual'),
			\man_page(section(_,_,ManFile), [])).
manual_file(Request) :-
	memberchk(path(Path), Request),
	existence_error(http_location, Path).


%%	init_thread_pools
%
%	Create pools of threads  as   defined  by  thread_pool_create/3.
%	Currently it defined two pools with `special' actions:
%
%	    * media
%	    Remote media.  Allow higher number of concurrent servers
%	    * www
%	    Local files.  Allow higher number of concurrent servers
%	    * search
%	    Allow not too many clients and use large stacks

init_thread_pools :-
	findall(Name-pool(Size,Options), thread_pool(Name, Size, Options), Pairs),
	group_pairs_by_key(Pairs, Grouped),
	maplist(start_pool, Grouped).

start_pool(Name-[pool(Size,Options)|_]) :-
	(   current_thread_pool(Name)
	->  thread_pool_destroy(Name)
	;   true
	),
	thread_pool_create(Name, Size, Options).

thread_pool(wiki,     20, [ local(2000), global(8000), trail(4000), backlog(5) ]).
thread_pool(download, 20, [ local(100),  global(200),  trail(200),  backlog(5) ]).
thread_pool(cgi,      20, [ local(100),  global(200),  trail(200),  backlog(5) ]).
thread_pool(complete, 20, [ local(100),  global(200),  trail(200),  backlog(5) ]).
