/*  Part of SWI-Prolog

    Author:        Jan Wielemaker
    E-mail:        J.Wielemaker@cs.vu.nl
    WWW:           http://www.swi-prolog.org
    Copyright (C): 2013, VU University Amsterdam

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

:- module(plweb_openid,
	  [ site_user/2,		% +Request, -User
	    site_user_logged_in/1,	% -User
	    site_user_property/2,	% +User, ?Property
	    user_profile_link//1,	% +User
	    current_user//1,		% +PageStyle
	    current_user//0,
	    login_link//1		% +Request
	  ]).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_session)).
:- use_module(library(http/http_wrapper)).
:- use_module(library(http/http_openid)).
:- use_module(library(http/http_header)).
:- use_module(library(http/http_path)).
:- use_module(library(http/html_write)).
:- use_module(library(http/html_head)).
:- use_module(library(http/recaptcha)).
:- use_module(library(http/http_stream)).
:- use_module(library(persistency)).
:- use_module(library(settings)).
:- use_module(library(debug)).
:- use_module(library(uuid)).
:- use_module(library(option)).

:- use_module(review).
:- use_module(pack).
:- use_module(wiki).
:- use_module(markitup).
:- use_module(tagit).
:- use_module(annotateit).

/** <module> Handle users of the SWI-Prolog website
*/

:- multifile
	http_openid:openid_hook/1.

:- persistent
	openid_user_server(user:atom,
			   server:atom),
	site_user(uuid:atom,
		  openid:atom,
		  name:atom,
		  email:atom,
		  home_url:atom),
	user_description(uuid:atom,
			 description:atom),
	stay_signed_in(openid:atom,
		       cookie:atom,
		       peer:atom,
		       time:integer,
		       expires:integer).

:- initialization
	db_attach('openid.db',
		  [ sync(close)
		  ]).

:- http_handler(root(user/create_profile),  create_profile, []).
:- http_handler(root(user/submit_profile),  submit_profile, []).
:- http_handler(root(user/logout),	    logout,         []).
:- http_handler(root(user/view_profile),    view_profile,   []).
:- http_handler(root(user/verify),          verify_user,    []).
:- http_handler(root(user/list),            list_users,     []).


		 /*******************************
		 *	    USER ADMIN		*
		 *******************************/

site_user_property(UUID, openid(OpenId)) :-
	site_user(UUID, OpenId, _, _, _).
site_user_property(UUID, name(Name)) :-
	site_user(UUID, _, Name, _, _).
site_user_property(UUID, email(Email)) :-
	site_user(UUID, _, _, Email, _).
site_user_property(UUID, home_url(Home)) :-
	site_user(UUID, _, _, _, Home).


		 /*******************************
		 *	 USER INTERACTION	*
		 *******************************/

:- multifile recaptcha:key/2.

:- setting(recaptcha:public_key, atom, '',
	   'reCAPTCHA public key').
:- setting(recaptcha:private_key, atom, '',
	   'reCAPTCHA private key').

recaptcha:key(public,  Key) :- setting(recaptcha:public_key,  Key).
recaptcha:key(private, Key) :- setting(recaptcha:private_key, Key).

%%	site_user(+Request, -User)
%
%	Demand the user to be logged on and, if this is the first logon,
%	verify the user and create a profile.

site_user(Request, User) :-
	openid_user(Request, OpenID, []),
	ensure_profile(OpenID, User).

ensure_profile(OpenID, User) :-
	(   site_user_property(User, openid(OpenID))
	->  true
	;   http_current_request(Request),
	    option(request_uri(RequestURI), Request),
	    http_link_to_id(create_profile, [return(RequestURI)], HREF),
	    http_redirect(moved_temporary, HREF, Request)
	).

%%	site_user_logged_in(-User) is semidet.
%
%	True when User is logged on.  Does not try to logon the user.

site_user_logged_in(User) :-
	openid_logged_in(OpenID),
	site_user_property(User, openid(OpenID)).


%%	create_profile(+Request).
%
%	Create a new user profile, and on success return to the original
%	location.

create_profile(Request) :-
	openid_user(Request, OpenID, []),
	http_parameters(Request,
			[ return(Return, [])
			]),
	reply_html_page(
	    wiki(create_profile),
	    title('Create user profile for SWI-Prolog'),
	    \create_profile(OpenID, Return)).


create_profile(OpenID, Return) -->
	{ (   site_user_property(User, openid(OpenID))
	  ->  Op = 'Update profile'
	  ;   uuid(User),		% new user
	      Op = 'Create profile'
	  )
	},
	html(h1(class(wiki), Op)),
	{ http_link_to_id(submit_profile, [], Action),
	  user_init_property(User, name(Name), ''),
	  user_init_property(User, email(Email), ''),
	  user_init_property(User, home_url(HomeURL), '')
	},
	html(form([ class(create_profile), method('POST'), action(Action) ],
		  [ input([type(hidden), name(return), value(Return)]),
		    input([type(hidden), name(uuid), value(User)]),
		    table([ tr([th('OpenID'),   td(input([ name(openid),
							   value(OpenID),
							   disabled(disabled)
							 ]))]),
			    tr([th('Name'),     td(input([ name(name),
							   value(Name),
							   placeholder('Displayed name')
							 ]))]),
			    tr([th('Email'),    td(input([ name(email),
							   value(Email),
							   placeholder('Your E-mail address')
							 ]))]),
			    tr([th('Home URL'), td(input([ name(home_url),
							   value(HomeURL),
							   placeholder('http://')
							 ]))]),
			    \description(User),
			    tr(td(colspan(2), \recaptcha([]))),
			    tr(td([colspan(2), align(right)],
				  input([type(submit), value(Op)])))
			  ])
		  ])),
	expain_create_profile.

user_init_property(User, P, Default) :-
	(   site_user_property(User, P)
	->  true
	;   http_session_data(ax(AX)),
	    ax(P, AX)
	->  true
	;   arg(1, P, Default)
	).

ax(email(Email), AX) :-
	memberchk(email(Email), AX).
ax(name(Name), AX) :-
	memberchk(fullname(Name), AX), !.
ax(name(Name), AX) :-
	memberchk(firstname(First), AX),
	memberchk(lastname(Last), AX), !,
	atomic_list_concat([First, Last], ' ', Name).
ax(name(Name), AX) :-
	memberchk(nickname(Name), AX), !.

expain_create_profile -->
	html({|html||
	       <div class="smallprint">
	       On this page, we ask you to proof you are human and
	       create a minimal profile. Your name is displayed along with comments
	       that you create.  Your E-mail and home URL are used to detect authorship of
	       packs. Your E-mail and home URL will not be displayed,
	       not be used for spamming and not be handed to third parties.
	       The editor can be used to add a short description about yourself.
	       This description is shown on your profile page that collects
	       your packages and ratings and reviews you performed.
	       </div>
	       |}).

%%	description(+UUID)//
%
%	Provide field for entering a description about the user.

description(UUID) -->
	{ (   user_description(UUID, Description)
	  ->  Extra = [value(Description)]
	  ;   Extra = []
	  )
	},
	html(tr(td(colspan(2),
		   \markitup([ id(description),
			       markup(pldoc),
			       cold(60),
			       rows(10)
			     | Extra
			     ])))).

%%	submit_profile(+Request)
%
%	Handle submission of the user profile

submit_profile(Request) :-
	openid_user(Request, OpenID, []),
	recaptcha_parameters(ReCAPTCHA),
	http_parameters(Request,
			[ uuid(User,         []),
			  name(Name,         [optional(true), default(anonymous)]),
			  email(Email,       [optional(true), default('')]),
			  home_url(Home,     [optional(true), default('')]),
			  description(Descr, [optional(true), default('')]),
			  return(Return, [])
			| ReCAPTCHA
			]),
	(   catch(recaptcha_verify(Request, ReCAPTCHA), E, true)
	->  (   var(E)
	    ->  retractall_site_user(User, OpenID, _, _, _),
		assert_site_user(User, OpenID, Name, Email, Home),
		update_description(User, Descr),
		http_redirect(moved_temporary, Return, Request)
	    ;	E = error(domain_error(recaptcha_response, _), _)
	    ->	retry_captcha('CAPTCHA required', '')
	    ;	message_to_string(E, Msg)
	    ->	retry_captcha('CAPTCHA processing error', Msg)
	    )
	;   retry_captcha('CAPTCHA verification failed', '')
	).

retry_captcha(Why, Warning) :-
	reply_html_page(
	    wiki,
	    title('CAPTCHA failed'),
	    [ h1(class(wiki), Why),
	      p(class(error), Warning),
	      p([ 'Please use the back button of your browser and ',
		  'try again'
		])
	    ]).


update_description(UUID, '') :- !,
	retractall_user_description(UUID, _).
update_description(UUID, Description) :- !,
	retractall_user_description(UUID, _),
	assert_user_description(UUID, Description).

%%	view_profile(+Request) is det.
%
%	HTTP handler showing the public profile for a user.

view_profile(Request) :-
	http_parameters(Request,
			[ user(UUID, [ optional(true) ])
			]),
	(   openid_logged_in(OpenID),
	    site_user_property(UUID, openid(OpenID))
	->  Options = [view(private), edit_link(true)]
	;   nonvar(UUID)
	->  Options = [view(public)]
	;   existence_error(http_parameter, user)
	),
	site_user_property(UUID, name(Name)),
	reply_html_page(
	    wiki,
	    title('User ~w'-[Name]),
	    [ \edit_link(UUID, Options),
	      h1(class(wiki), 'Profile for user ~w'-[Name]),
	      \view_profile(UUID, Options)
	    ]).

view_profile(UUID, Options) -->
	private_profile(UUID, Options),
	user_description(UUID, Options),
	user_tags(UUID, []),
	user_annotations(UUID),
	user_packs(UUID),
	profile_reviews(UUID).

%%	private_profile(+UUID, +Options)// is det.
%
%	If the user is viewing his/her own profile, show a table holding
%	the private profile information.

private_profile(_UUID, Options) -->
	{ \+ option(view(private), Options) }, !.
private_profile(UUID, _Options) -->
	html([ div(class('private-profile'),
		   [ h2(class(wiki),
			[ 'Private profile data',
			  \link_list_users
			]),
		     table([ \profile_data(UUID, 'Name',      name),
			     \profile_data(UUID, 'OpenID',    openid),
			     \profile_data(UUID, 'E-Mail',    email),
			     \profile_data(UUID, 'Home page', home_url)
			   ])
		   ]),
	       div(class(smallprint),
		   'The above private information is shown only to the owner.')
	     ]).

link_list_users -->
	{ http_link_to_id(list_users, [], HREF)
	},
	html(a([ href(HREF),
		 style('float:right; font-size:60%; font-style:italic; font-weight:normal')
	       ], 'other users')).


create_profile_link(HREF) :-
	http_current_request(Request),
	option(request_uri(Here), Request),
	http_link_to_id(create_profile, [return(Here)], HREF).

profile_data(UUID, Label, Field) -->
	{ Term =.. [Field,Value],
	  site_user_property(UUID, Term),
	  value_dom(Field, Value, DOM)
	},
	html(tr([ th([Label,:]),
		  td(DOM)
		])).

value_dom(name,  Name,  Name) :- !.
value_dom(email, Email, a(href('mailto:'+Email), Email)) :- !.
value_dom(_,     URL,   a(href(URL), URL)).

%%	user_description(UUID, +Options)// is det.
%
%	Show user description

user_description(UUID, _Options) -->
	{ user_description(UUID, Description),
	  Description \== '', !,
	  atom_codes(Description, Codes),
	  wiki_file_codes_to_dom(Codes, /, DOM0),
	  clean_dom(DOM0, DOM)
	},
	html(DOM).
user_description(_UUID, Options) -->
	{ option(edit_link(true), Options),
	  create_profile_link(Edit)
	},
	html([ i('No description.'),
	       ' Click ', a(href(Edit), here), ' to create one'
	     ]).
user_description(_, _) --> [].

clean_dom([p(X)], X) :- !.
clean_dom(X, X).

edit_link(_UUID, Options) -->
	{ option(edit_link(true), Options), !,
	  create_profile_link(Edit)
	},
	html(div(class('edit-profile'),
		 [ a(href(Edit), 'Edit'), ' profile'])).
edit_link(_, _) --> [].


%%	user_packs(UUID)// is det.
%
%	Show a filtered version of the pack table, holding the packs
%	created by this user.

user_packs(UUID) -->
	{ setof(Pack, current_pack([author(UUID)], Pack), Packs), !,
	  sort_packs(rating, Packs, Sorted),
	  site_user_property(UUID, name(Name))
	},
	html([ h2(class(wiki), 'Packages by ~w'-[Name])
	     ]),
	pack_table(Sorted, []),
	html([ div(class(smallprint),
		   [ 'This list contains packages whose author name, e-mail ',
		     'or homepage url matches the profile information.'
		   ])
	     ]).
user_packs(_) -->
	[].


%%	list_users(+Request)
%
%	HTTP handler to list known users.

list_users(_Request) :-
	site_user_logged_in(_User), !,
	findall(user(Kudos, UUID, Annotations, Tags),
		site_kudos(UUID, Annotations, Tags, Kudos),
		Users),
	sort(Users, ByKudos), reverse(ByKudos, BestFirst),
	reply_html_page(
	    reply_html_page(users),
	    title('SWI-Prolog site users'),
	    [ \explain_user_listing,
	      \html_requires(css('stats.css')),
	      table(class(block),
		    [ \user_table_header
		    | \user_rows(BestFirst)
		    ])
	    ]).
list_users(_Request) :-
	reply_html_page(
	    reply_html_page(users),
	    title('Permission denied'),
	    [ \explain_user_listing_not_logged_on
	    ]).

site_kudos(UUID, Annotations, Tags, Kudos) :-
	site_user(UUID, _, _, _, _),
	user_annotation_count(UUID, Annotations),
	user_tag_count(UUID, Tags),
	Kudos is Annotations*10+Tags.

explain_user_listing -->
	html({|html||
	      <h1 class="wiki">SWI-Prolog site users</h1>

	      <p>Below is a listing of all registered users with some
	      basic properties.
	     |}).

explain_user_listing_not_logged_on -->
	html({|html||
	      <h1 class="wiki">Permission denied</h1>

	      <p class="warning">A listing of all registered users is only
	      available to users who are logged in.
	     |}).

user_rows([]) --> [].
user_rows([H|T]) --> user_row(H), user_rows(T).

user_table_header -->
	html(tr([th('User'),
		 th('#Comments'),
		 th('#Tags')
		])).

user_row(user(_Kudos, UUID, Annotations, Tags)) -->
	html(tr([td(\user_profile_link(UUID)),
		 td(Annotations),
		 td(Tags)
		])).


		 /*******************************
		 *	     COMPONENTS		*
		 *******************************/

%%	user_profile_link(+UUID)//
%
%	Create a link to the profile of a user.

user_profile_link(UUID) -->
	{ site_user_property(UUID, name(Name)),
	  http_link_to_id(view_profile, [user(UUID)], HREF)
	}, !,
	html(a([class(user), href(HREF)], Name)).


		 /*******************************
		 *     OPENID CUSTOMIZATION	*
		 *******************************/

stay_login_cookie(swipl_login).

http_openid:openid_hook(trusted(OpenId, Server)) :-
	openid_user_server(OpenId, Server), !.
http_openid:openid_hook(trusted(OpenId, Server)) :-
	assert_openid_user_server(OpenId, Server), !.
http_openid:openid_hook(stay_signed_in(OpenId)) :-
	assertion(in_header_state),
	http_session_cookie(Cookie),
	get_time(NowF),
	Now is round(NowF),
	http_current_request(Request),
	http_peer(Request, Peer),
	Expires is Now+31*24*60*60,	% 31 days from now
	assert_stay_signed_in(OpenId, Cookie, Peer, Now, Expires),
	http_session_option(path(Path)),
	debug(openid(stay_signed_in),
	      'Created stay-signed-in for ~q', [OpenId]),
	http_timestamp(Expires, RFC1123),
	stay_login_cookie(CookieName),
	format('Set-Cookie: ~w=~w; Expires=~w; path=~w\r\n',
	       [CookieName, Cookie, RFC1123, Path]).
http_openid:openid_hook(logout(OpenId)) :-
	nonvar(OpenId),
	assertion(in_header_state),
	retractall_stay_signed_in(OpenId, _, _, _, _),
	http_session_option(path(Path)),
	stay_login_cookie(CookieName),
	format('Set-Cookie: ~w=; \c
	        expires=Tue, 01-Jan-1970 00:00:00 GMT; \c
		path=~w\r\n',
	       [CookieName, Path]),
	fail.
http_openid:openid_hook(logged_in(OpenId)) :-
	(   http_in_session(_),
	    http_session_data(openid(OpenId))
	->  true
	;   http_current_request(Request),
	    memberchk(cookie(Cookies), Request),
	    memberchk(swipl_login=Cookie, Cookies),
	    stay_signed_in(OpenId, Cookie, _Peer, _Time, _Expires)
	->  http_open_session(_, []),
	    http_session_assert(openid(OpenId)),
	    debug(openid(stay_signed_in),
		  'Granted stay-signed-in for ~q', [OpenId])
	).


%%	yadis:xrds_specified_location(+Server, -XRDSLocation)
%
%	Hacks to deal with broken Yadis support.
%
%	  - Google does not support Yadis discovery, but does have an
%	    XRSD document, so we fake its location.
%	  - stackexchange.com serves an _OP Identifier Element_ instead
%	    of an _Claimed Identifier Element_ when doing Yadis
%	    discovery on the real OpenID.

:- multifile
	yadis:xrds_specified_location/2.

yadis:xrds_specified_location('http://google.com/',
			      'https://www.google.com/accounts/o8/id').
yadis:xrds_specified_location(StackOverFlow, -) :-
	sub_atom(StackOverFlow, 0, _, A, 'https://openid.stackexchange.com/'),
	A > 0.


in_header_state :-
	current_output(CGI),
	cgi_property(CGI, state(header)), !.

:- http_handler(openid(login),  plweb_login_page, [id(swipl_login)]).

%%	plweb_login_page(+Request)
%
%	HTTP handler that  overrules  the   location  openid(login)  for
%	customizating the -very basic- login page.

plweb_login_page(Request) :-
	http_open_session(_, []),
	http_parameters(Request,
			[ 'openid.return_to'(ReturnTo, [])
			]),
	http_link_to_id(verify_user, [], Action),
	quick_buttons(Buttons),
	reply_html_page(wiki,
			[ title('SWI-Prolog login')
			],
			[ \openid_login_form(
			       ReturnTo,
			       [ show_stay(true),
				 action(Action),
				 buttons(Buttons)
			       ]),
			  \explain
			]).

explain -->
	html([ div(class(smallprint),
		   [ p([ 'Actions such as rating, commenting and tagging ',
			 'requires you to be signed in. ',
			 'We use ', a(href('http://openid.net/'), 'OpenID'), '. ',
			 'Currently, we accept any OpenID provider. ',
			 'Tested with ', \openid_ok
		       ]),
		     p([ 'After logging in for the first time, we will ask for ',
			 'some additional information.  All information is ',
			 'optional.'
		       ])
		   ])
	     ]).


%%	quick_buttons(-Buttons) is det.
%
%	Create a list of img(Attributes) terms for quick login.

quick_buttons(Buttons) :-
	findall(Img, quick_button(Img), Buttons).

quick_button(img([ src(Icon),
		   href(Provider),
		   alt(Name),
		   title('Sign in with '+Name)
		 ])) :-
	openid_provider(2, Provider, Name, ImgName),
	http_absolute_location(icons(ImgName), Icon, []).

openid_provider(2, 'http://google.com', 'Google', 'social_google_box.png').
openid_provider(2, 'http://yahoo.com',  'Yahoo', 'social_yahoo_box_lilac.png').
openid_provider(1, 'https://openid.stackexchange.com/%user%', 'StackExchange', -).
openid_provider(1, 'http://%user%.myopenid.com', 'MyOpenID', -).

openid_ok -->
	{ Term = openid_provider(_Version, _URL, _Name, _Icon),
	  findall(Term, Term, Terms)
	},
	openid_ok(Terms).

openid_ok([]) --> [].
openid_ok([H|T]) -->
	openid_ok1(H),
	(   {T == []}
	->  []
	;   html(', '),
	    openid_ok(T)
	).

openid_ok1(openid_provider(2, URL, Name, _Icon)) --> !,
	html(a(href(URL), Name)).
openid_ok1(openid_provider(1, URL, Name, _Icon)) --> !,
	html([ Name, ' using the url ',
	       span(class('openid-url-pattern'), URL)
	     ]).


%%	verify_user(+Request)
%
%	HTTP handler for SWI-Prolog  site   login.  Calls openid_verify,
%	asking for additional attribute exchange.

verify_user(Request) :-
	openid_verify([ ax([ email(_, [required]),
			     nickname(_),
			     fullname(_),
			     firstname(_),
			     lastname(_)
			   ])
		      ], Request).


		 /*******************************
		 *	      LOGOUT		*
		 *******************************/

%%	logout(+Request)
%
%	Logout the current user and reload the current page.

logout(_Request) :-
	openid_logged_in(OpenId), !,
	openid_logout(OpenId),
	reply_html_page(
	    wiki,
	    title('Logged out'),
	    [ h1(class(wiki), 'Logout'),
	      p('Thanks for using www.swi-prolog.org')
	    ]).
logout(_Request) :-
	reply_html_page(
	    wiki,
	    title('Not logged in'),
	    [ h1(class(wiki), 'Logout'),
	      p(class(warning), 'You were not logged in')
	    ]).


%%	current_user//

current_user -->
	current_user(default).

current_user(Style) -->
	{ Style \== create_profile,
	  openid_logged_in(OpenID), !,
	  ensure_profile(OpenID, User),
	  (   site_user_property(User, name(Name)),
	      Name \== ''
	  ->  Display = Name
	  ;   Display = OpenID
	  ),
	  http_link_to_id(view_profile, [], Profile),
	  http_link_to_id(logout, [], Logout)
	},
	html(div(class('current-user'),
		 [ a([href(Profile)], Display),
		   ' (', a([href(Logout)], 'logout'), ')'
		 ])).
current_user(Style) -->
	{ Style \== create_profile,
	  http_current_request(Request), !
	},
	html(div(class('current-user'),
		 \login_link(Request))).
current_user(_Style) -->
	[].

%%	login_link(+Request)//
%
%	Create a link to login, which returns to the current page.

login_link(Request) -->
	{ (   memberchk(request_uri(Here), Request)
	  ->  Attrs = ['openid.return_to'(Here)]
	  ;   Attrs = []
	  ),
	  http_link_to_id(swipl_login, Attrs, Login)
	},
	html(a([class(signin), href(Login)], login)).
