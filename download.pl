/*  File:    download.pl
    Author:  Jan Wielemaker
    Created: Jan 14 2009
    Purpose: Provide download links
*/

:- module(plweb_download, []).
:- use_module(library(http/html_write)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_path)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/dcg_basics)).
:- use_module(library(broadcast)).
:- use_module(library(pairs)).
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(wiki).

%%	download(+Request) is det.
%
%	HTTP handler for SWI-Prolog download pages.

:- http_handler(download(devel),  download_table, []).
:- http_handler(download(stable), download_table, []).
:- http_handler(download(.),	  download,	  [prefix, priority(10)]).

%%	download_table(+Request)
%
%	Provide a table with possible download targets.

download_table(Request) :-
	http_parameters(Request,
			[ show(Show, [oneof([all,latest]), default(latest)])
			]),
	memberchk(path(Path), Request),
	http_absolute_location(root(download), DownLoadRoot, []),
	atom_concat(DownLoadRoot, DownLoadDir, Path),
	absolute_file_name(download(DownLoadDir),
			   Dir,
			   [ file_type(directory),
			     access(read)
			   ]),
	list_downloads(Dir, [show(Show), request(Request)]).

%%	list_downloads(+Directory)

list_downloads(Dir, Options) :-
	reply_html_page(title('SWI-Prolog downloads'),
			[ \wiki(Dir, 'header.txt'),
			  table(class(downloads),
				\download_table(Dir, Options)),
			  \wiki(Dir, 'footer.txt')
			]).

wiki(Dir, File) -->
	{ concat_atom([Dir, /, File], WikiFile),
	  access_file(WikiFile, read), !,
	  wiki_file_to_dom(WikiFile, DOM)
	},
	html(DOM).
wiki(_, _) -->
	[].

download_table(Dir, Options) -->
	list_files(Dir, bin, 'Binaries',      Options),
	list_files(Dir, src, 'Sources',       Options),
	list_files(Dir, doc, 'Documentation', Options),
	toggle_show(Options).

%%	toggle_show(+Options) is det.
%
%	Add a toggle to switch between   showing only the latest version
%	and all versions.

toggle_show(Options) -->
	{ option(request(Request), Options),
	  memberchk(path(Path), Request), !,
	  file_base_name(Path, MySelf),
	  (   option(show(all), Options)
	  ->  NewShow = latest
	  ;   NewShow = all
	  )
	},
	html(tr(td([class(toggle), colspan(3)],
		   a(href(MySelf+'?show='+NewShow),
		     [ 'Show ', NewShow, ' files' ])))).
toggle_show(_) -->
	[].

%%	list_files(+Dir, +SubDir, +Label, +Options) is det.
%
%	Create table rows for all  files   in  Dir/SubDir.  If files are
%	present, emit a =tr= with Label  and   a  =tr= row for each each
%	matching file.  Options are:
%	
%	    * show(Show)
%	    One of =all= or =latest= (default).

list_files(Dir, SubDir, Label, Options) -->
	{ concat_atom([Dir, /, SubDir], Directory),
	  atom_concat(Directory, '/*', Pattern),
	  expand_file_name(Pattern, Files),
	  classsify_files(Files, Classified),
	  sort_files(Classified, Sorted, Options),
	  Sorted \== [], !
	},
	html(tr(th(colspan(3), Label))),
	list_files(Sorted).
list_files(_, _, _, _) -->
	[].
	
list_files([]) --> [].
list_files([H|T]) -->
	list_file(H),
	list_files(T).

list_file(File) -->
	html(tr([ td(\file_icon(File)),
		  td(\file_size(File)),
		  td(\file_description(File))
		])).

file_icon(file(Type, PlatForm, _, _, _)) -->
	{ icon_for_file(Type, PlatForm, Icon, Alt), !,
	  http_absolute_location(icons(Icon), HREF, [])
	},
	html(img([src(HREF), alt(Alt)])).
file_icon(_) -->
	html(?).			% no defined icon

icon_for_file(bin, linux(_),	  
	      'linux32.gif', 'Linux RPM').
icon_for_file(bin, macos(_,_),
	      'mac.gif', 'MacOSX version').
icon_for_file(bin, windows(win32),
	      'win32.gif', 'Windows version (32-bits)').
icon_for_file(bin, windows(win64),
	      'win64.gif', 'Windows version (64-bits)').
icon_for_file(src, _,
	      'src.gif', 'Source archive').
icon_for_file(_, pdf,
	      'pdf.gif', 'PDF file').


file_size(file(_, _, _, _, Path)) -->
	{ size_file(Path, Bytes)
	},
	html('~D bytes'-[Bytes]).
	  
file_description(file(bin, PlatForm, Version, _, Path)) -->
	{ down_file_href(Path, HREF)
	},
	html([ a(href(HREF),
		 [ 'SWI-Prolog/XPCE ', \version(Version), ' for ',
		   \platform(PlatForm)
		 ]),
	       \platform_notes(PlatForm, Path)
	     ]).
file_description(file(src, _, Version, _, Path)) -->
	{ down_file_href(Path, HREF)
	},
	html([ a(href(HREF),
		 [ 'SWI-Prolog source for ', \version(Version)
		 ])
	     ]).
file_description(file(doc, _, Version, _, Path)) -->
	{ down_file_href(Path, HREF)
	},
	html([ a(href(HREF),
		 [ 'SWI-Prolog ', \version(Version),
		   ' reference manual in PDF'
		 ])
	     ]).

version(version(Major, Minor, Patch)) -->
	html(b('~w.~w.~w'-[Major, Minor, Patch])).

down_file_href(Path, HREF) :-
	absolute_file_name(download(.),
			   Dir,
			   [ file_type(directory),
			     access(read)
			   ]),
	atom_concat(Dir, SlashLocal, Path),
	delete_leading_slash(SlashLocal, Local),
	http_absolute_location(download(Local), HREF, []).
			     
delete_leading_slash(SlashPath, Path) :-
	atom_concat(/, Path, SlashPath), !.
delete_leading_slash(Path, Path).

platform(macos(Name, CPU)) -->
	html(['MacOSX ', \html_macos_version(Name), ' on ', b(CPU)]).
platform(windows(win32)) -->
	html(['Windows NT/2000/XP/Vista']).
platform(windows(win64)) -->
	html(['Windows XP/Vista 64-bit edition']).

html_macos_version(tiger)   --> html('10.4 (tiger)').
html_macos_version(leopard) --> html('10.5 (leopard)').
html_macos_version(OS)	    --> html(OS).

%%	platform_notes(+Platform, +Path) is det.
%
%	Include notes on the platform. These notes  are stored in a wiki
%	file in the same directory as the download file.

platform_notes(Platform, Path) -->
	{ file_directory_name(Path, Dir),
	  platform_note_file(Platform, File),
	  concat_atom([Dir, /, File], NoteFile),
	  access_file(NoteFile, read), !,
	  wiki_file_to_dom(NoteFile, DOM)
	},
	html(DOM).
platform_notes(_, _) -->
	[].

platform_note_file(linux(_,_),	   'linux.txt').
platform_note_file(windows(win32), 'win32.txt').
platform_note_file(windows(win64), 'win64.txt').
platform_note_file(macos(_,_),	   'macosx.txt').

		 /*******************************
		 *	   CLASSIFY FILES	*
		 *******************************/

classsify_files([], []).
classsify_files([H0|T0], [H|T]) :-
	classsify_file(H0, H), !,
	classsify_files(T0, T).
classsify_files([_|T0], T) :-
	classsify_files(T0, T).

%%	classsify_file(+Path, -Term) is semidet.

classsify_file(Path, file(Type, Platform, Version, Name, Path)) :-
	file_base_name(Path, Name),
	atom_codes(Name, Codes),
	phrase(file(Type, Platform, Version), Codes).

file(bin, macos(OSVersion, CPU), Version) -->
	"swi-prolog-devel-", long_version(Version), "-",
	macos_version(OSVersion), "-", 
	macos_cpu(CPU),
	".mpkg.zip", !.
file(bin, windows(WinType), Version) -->
	win_type(WinType), "pl",
	short_version(Version),
	".exe", !.
file(bin, linux(rpm, suse), Version) -->
	"pl-", long_version(Version), "-", digits(_Build),
	".i586.rpm", !.
file(src, tgz, Version) -->
	"pl-", long_version(Version), ".tar.gz", !.
file(doc, pdf, Version) -->
	"SWI-Prolog-", long_version(Version), ".pdf", !.

macos_version(tiger)   --> "tiger".
macos_version(leopard) --> "leopard".

macos_cpu(ppc)   --> "ppc".
macos_cpu(intel) --> "intel".

win_type(win32) --> "w32".
win_type(win64) --> "w64".

long_version(version(Major, Minor, Patch)) -->
	int(Major, 1), ".", int(Minor, 1), ".", int(Patch, 2), !.
	
int(Value, MaxDigits) -->
	digits(Digits),
	{ length(Digits, Len),
	  Len =< MaxDigits,
	  number_codes(Value, Digits)
	}.

short_version(version(Major, Minor, Patch)) -->
	digits(Digits),
	{   Digits = [D1,D2,D3]
	->  number_codes(Major, [D1]),
	    number_codes(Minor, [D2]),
	    number_codes(Patch, [D3])
	;   Digits = [D1,D2,D3,D4]
	->  number_codes(Major, [D1]),
	    number_codes(Minor, [D2]),
	    number_codes(Patch, [D3,D4])
	}.
			 
%%	sort_files(+In, -Out, +Options)
%
%	Sort files by type and version. Type: linux, windows, mac, src,
%	doc.  Versions: latest first.
%	
%	Options:
%	
%	    * show(Show)
%	    One of =all= or =latest=.

sort_files(In, Out, Options) :-
	map_list_to_pairs(map_type, In, Typed),
	keysort(Typed, TSorted),
	group_pairs_by_key(TSorted, TGrouped),
	maplist(sort_group_by_version, TGrouped, TGroupSorted),
	(   option(show(all), Options)
	->  pairs_values(TGroupSorted, TValues),
	    flatten(TValues, Out)
	;   take_latest(TGroupSorted, Out)
	).

map_type(File, Tag) :-
	File = file(Type, Platform, _Version, _Name, _Path),
	type_tag(Type, Platform, Tag).

type_tag(bin, linux(A,B), tag(0, linux(A,B))) :- !.
type_tag(bin, windows(A), tag(1, windows(A))) :- !.
type_tag(bin, macos(A,B), tag(2, macos(A,B))) :- !.
type_tag(src, Format,     tag(3, Format)) :- !.
type_tag(doc, Format,     tag(4, Format)) :- !.
type_tag(X,   Y,	  tag(5, X-Y)).

sort_group_by_version(Tag-Files, Tag-Sorted) :-
	map_list_to_pairs(tag_version, Files, TFiles),
	keysort(TFiles, TRevSorted),
	pairs_values(TRevSorted, RevSorted),
	reverse(RevSorted, Sorted).

tag_version(File, Version) :-
	File = file(_,_,Version,_,_).

take_latest([], []).
take_latest([_-[H|_]|T0], [H|T]) :- !,
	take_latest(T0, T).
take_latest([_-[]|T0], T) :- !,		% emty set
	take_latest(T0, T).


		 /*******************************
		 *	     DOWNLOAD		*
		 *******************************/
	  
%%	download(+Request) is det.
%
%	Actually download a file.

download(Request) :-
	http_absolute_location(download(.), DownloadRoot, []),
	memberchk(path(Path), Request),
	atom_concat(DownloadRoot, Download, Path),
	absolute_file_name(download(Download),
			   AbsFile,
			   [ access(read)
			   ]),
	http_reply_file(AbsFile, [], Request),
	broadcast(download(Download)).