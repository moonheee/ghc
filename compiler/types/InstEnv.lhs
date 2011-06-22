%
% (c) The University of Glasgow 2006
% (c) The GRASP/AQUA Project, Glasgow University, 1992-1998
%
\section[InstEnv]{Utilities for typechecking instance declarations}

The bits common to TcInstDcls and TcDeriv.

\begin{code}
module InstEnv (
	DFunId, OverlapFlag(..),
	Instance(..), pprInstance, pprInstanceHdr, pprInstances, 
	instanceHead, mkLocalInstance, mkImportedInstance,
	instanceDFunId, setInstanceDFunId, instanceRoughTcs,

	InstEnv, emptyInstEnv, extendInstEnv, 
	extendInstEnvList, lookupInstEnv, instEnvElts,
	classInstances, instanceBindFun,
	instanceCantMatch, roughMatchTcs
    ) where

#include "HsVersions.h"

import Class
import Var
import VarSet
import Name
import TcType
import TyCon
import Unify
import Outputable
import BasicTypes
import UniqFM
import Id
import FastString

import Data.Maybe	( isJust, isNothing )
\end{code}


%************************************************************************
%*									*
\subsection{The key types}
%*									*
%************************************************************************

\begin{code}
data Instance 
  = Instance { is_cls  :: Name  -- Class name

                -- Used for "rough matching"; see Note [Rough-match field]
                -- INVARIANT: is_tcs = roughMatchTcs is_tys
             , is_tcs  :: [Maybe Name]  -- Top of type args

                -- Used for "proper matching"; see Note [Proper-match fields]
             , is_tvs  :: TyVarSet      -- Template tyvars for full match
             , is_tys  :: [Type]        -- Full arg types
                -- INVARIANT: is_dfun Id has type 
                --      forall is_tvs. (...) => is_cls is_tys

             , is_dfun :: DFunId -- See Note [Haddock assumptions]
             , is_flag :: OverlapFlag   -- See detailed comments with
                                        -- the decl of BasicTypes.OverlapFlag
    }
\end{code}

Note [Rough-match field]
~~~~~~~~~~~~~~~~~~~~~~~~~~~
The is_cls, is_tcs fields allow a "rough match" to be done
without poking inside the DFunId.  Poking the DFunId forces
us to suck in all the type constructors etc it involves,
which is a total waste of time if it has no chance of matching
So the Name, [Maybe Name] fields allow us to say "definitely
does not match", based only on the Name.

In is_tcs, 
    Nothing  means that this type arg is a type variable

    (Just n) means that this type arg is a
		TyConApp with a type constructor of n.
		This is always a real tycon, never a synonym!
		(Two different synonyms might match, but two
		different real tycons can't.)
		NB: newtypes are not transparent, though!

Note [Proper-match fields]
~~~~~~~~~~~~~~~~~~~~~~~~~
The is_tvs, is_tys fields are simply cached values, pulled
out (lazily) from the dfun id. They are cached here simply so 
that we don't need to decompose the DFunId each time we want 
to match it.  The hope is that the fast-match fields mean
that we often never poke th proper-match fields

However, note that:
 * is_tvs must be a superset of the free vars of is_tys

 * The is_dfun must itself be quantified over exactly is_tvs
   (This is so that we can use the matching substitution to
    instantiate the dfun's context.)

Note [Haddock assumptions]
~~~~~~~~~~~~~~~~~~~~~~~~~~
For normal user-written instances, Haddock relies on

 * the SrcSpan of
 * the Name of
 * the is_dfun of
 * an Instance

being equal to

  * the SrcSpan of
  * the instance head type of
  * the InstDecl used to construct the Instance.

\begin{code}
instanceDFunId :: Instance -> DFunId
instanceDFunId = is_dfun

setInstanceDFunId :: Instance -> DFunId -> Instance
setInstanceDFunId ispec dfun
   = ASSERT( idType dfun `eqType` idType (is_dfun ispec) )
	-- We need to create the cached fields afresh from
	-- the new dfun id.  In particular, the is_tvs in
	-- the Instance must match those in the dfun!
	-- We assume that the only thing that changes is
	-- the quantified type variables, so the other fields
	-- are ok; hence the assert
     ispec { is_dfun = dfun, is_tvs = mkVarSet tvs, is_tys = tys }
   where 
     (tvs, _, _, tys) = tcSplitDFunTy (idType dfun)

instanceRoughTcs :: Instance -> [Maybe Name]
instanceRoughTcs = is_tcs
\end{code}

\begin{code}
instance NamedThing Instance where
   getName ispec = getName (is_dfun ispec)

instance Outputable Instance where
   ppr = pprInstance

pprInstance :: Instance -> SDoc
-- Prints the Instance as an instance declaration
pprInstance ispec
  = hang (pprInstanceHdr ispec)
	2 (ptext (sLit "--") <+> pprNameLoc (getName ispec))

-- * pprInstanceHdr is used in VStudio to populate the ClassView tree
pprInstanceHdr :: Instance -> SDoc
-- Prints the Instance as an instance declaration
pprInstanceHdr ispec@(Instance { is_flag = flag })
  = ptext (sLit "instance") <+> ppr flag
       <+> sep [pprThetaArrowTy theta, ppr res_ty]
  where
    dfun = is_dfun ispec
    (_, theta, res_ty) = tcSplitSigmaTy (idType dfun)
	-- Print without the for-all, which the programmer doesn't write

pprInstances :: [Instance] -> SDoc
pprInstances ispecs = vcat (map pprInstance ispecs)

instanceHead :: Instance -> ([TyVar], ThetaType, Class, [Type])
instanceHead ispec = (tvs, theta, cls, tys)
   where
     (tvs, theta, tau) = tcSplitSigmaTy (idType dfun)
     (cls, tys)        = tcSplitDFunHead tau
     dfun              = is_dfun ispec

mkLocalInstance :: DFunId
                -> OverlapFlag
                -> Instance
-- Used for local instances, where we can safely pull on the DFunId
mkLocalInstance dfun oflag
  = Instance {	is_flag = oflag, is_dfun = dfun,
		is_tvs = mkVarSet tvs, is_tys = tys,
                is_cls = className cls, is_tcs = roughMatchTcs tys }
  where
    (tvs, _, cls, tys) = tcSplitDFunTy (idType dfun)

mkImportedInstance :: Name -> [Maybe Name]
		   -> DFunId -> OverlapFlag -> Instance
-- Used for imported instances, where we get the rough-match stuff
-- from the interface file
mkImportedInstance cls mb_tcs dfun oflag
  = Instance {	is_flag = oflag, is_dfun = dfun,
		is_tvs = mkVarSet tvs, is_tys = tys,
		is_cls = cls, is_tcs = mb_tcs }
  where
    (tvs, _, _, tys) = tcSplitDFunTy (idType dfun)

roughMatchTcs :: [Type] -> [Maybe Name]
roughMatchTcs tys = map rough tys
  where
    rough ty = case tcSplitTyConApp_maybe ty of
		  Just (tc,_) -> Just (tyConName tc)
		  Nothing     -> Nothing

instanceCantMatch :: [Maybe Name] -> [Maybe Name] -> Bool
-- (instanceCantMatch tcs1 tcs2) returns True if tcs1 cannot
-- possibly be instantiated to actual, nor vice versa; 
-- False is non-committal
instanceCantMatch (Just t : ts) (Just a : as) = t/=a || instanceCantMatch ts as
instanceCantMatch _             _             =  False  -- Safe
\end{code}


Note [Overlapping instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Overlap is permitted, but only in such a way that one can make
a unique choice when looking up.  That is, overlap is only permitted if
one template matches the other, or vice versa.  So this is ok:

  [a]  [Int]

but this is not

  (Int,a)  (b,Int)

If overlap is permitted, the list is kept most specific first, so that
the first lookup is the right choice.


For now we just use association lists.

\subsection{Avoiding a problem with overlapping}

Consider this little program:

\begin{pseudocode}
     class C a        where c :: a
     class C a => D a where d :: a

     instance C Int where c = 17
     instance D Int where d = 13

     instance C a => C [a] where c = [c]
     instance ({- C [a], -} D a) => D [a] where d = c

     instance C [Int] where c = [37]

     main = print (d :: [Int])
\end{pseudocode}

What do you think `main' prints  (assuming we have overlapping instances, and
all that turned on)?  Well, the instance for `D' at type `[a]' is defined to
be `c' at the same type, and we've got an instance of `C' at `[Int]', so the
answer is `[37]', right? (the generic `C [a]' instance shouldn't apply because
the `C [Int]' instance is more specific).

Ghc-4.04 gives `[37]', while ghc-4.06 gives `[17]', so 4.06 is wrong.  That
was easy ;-)  Let's just consult hugs for good measure.  Wait - if I use old
hugs (pre-September99), I get `[17]', and stranger yet, if I use hugs98, it
doesn't even compile!  What's going on!?

What hugs complains about is the `D [a]' instance decl.

\begin{pseudocode}
     ERROR "mj.hs" (line 10): Cannot build superclass instance
     *** Instance            : D [a]
     *** Context supplied    : D a
     *** Required superclass : C [a]
\end{pseudocode}

You might wonder what hugs is complaining about.  It's saying that you
need to add `C [a]' to the context of the `D [a]' instance (as appears
in comments).  But there's that `C [a]' instance decl one line above
that says that I can reduce the need for a `C [a]' instance to the
need for a `C a' instance, and in this case, I already have the
necessary `C a' instance (since we have `D a' explicitly in the
context, and `C' is a superclass of `D').

Unfortunately, the above reasoning indicates a premature commitment to the
generic `C [a]' instance.  I.e., it prematurely rules out the more specific
instance `C [Int]'.  This is the mistake that ghc-4.06 makes.  The fix is to
add the context that hugs suggests (uncomment the `C [a]'), effectively
deferring the decision about which instance to use.

Now, interestingly enough, 4.04 has this same bug, but it's covered up
in this case by a little known `optimization' that was disabled in
4.06.  Ghc-4.04 silently inserts any missing superclass context into
an instance declaration.  In this case, it silently inserts the `C
[a]', and everything happens to work out.

(See `basicTypes/MkId:mkDictFunId' for the code in question.  Search for
`Mark Jones', although Mark claims no credit for the `optimization' in
question, and would rather it stopped being called the `Mark Jones
optimization' ;-)

So, what's the fix?  I think hugs has it right.  Here's why.  Let's try
something else out with ghc-4.04.  Let's add the following line:

    d' :: D a => [a]
    d' = c

Everyone raise their hand who thinks that `d :: [Int]' should give a
different answer from `d' :: [Int]'.  Well, in ghc-4.04, it does.  The
`optimization' only applies to instance decls, not to regular
bindings, giving inconsistent behavior.

Old hugs had this same bug.  Here's how we fixed it: like GHC, the
list of instances for a given class is ordered, so that more specific
instances come before more generic ones.  For example, the instance
list for C might contain:
    ..., C Int, ..., C a, ...  
When we go to look for a `C Int' instance we'll get that one first.
But what if we go looking for a `C b' (`b' is unconstrained)?  We'll
pass the `C Int' instance, and keep going.  But if `b' is
unconstrained, then we don't know yet if the more specific instance
will eventually apply.  GHC keeps going, and matches on the generic `C
a'.  The fix is to, at each step, check to see if there's a reverse
match, and if so, abort the search.  This prevents hugs from
prematurely chosing a generic instance when a more specific one
exists.

--Jeff

BUT NOTE [Nov 2001]: we must actually *unify* not reverse-match in
this test.  Suppose the instance envt had
    ..., forall a b. C a a b, ..., forall a b c. C a b c, ...
(still most specific first)
Now suppose we are looking for (C x y Int), where x and y are unconstrained.
	C x y Int  doesn't match the template {a,b} C a a b
but neither does 
	C a a b  match the template {x,y} C x y Int
But still x and y might subsequently be unified so they *do* match.

Simple story: unify, don't match.


%************************************************************************
%*									*
		InstEnv, ClsInstEnv
%*									*
%************************************************************************

A @ClsInstEnv@ all the instances of that class.  The @Id@ inside a
ClsInstEnv mapping is the dfun for that instance.

If class C maps to a list containing the item ([a,b], [t1,t2,t3], dfun), then

	forall a b, C t1 t2 t3  can be constructed by dfun

or, to put it another way, we have

	instance (...) => C t1 t2 t3,  witnessed by dfun

\begin{code}
---------------------------------------------------
type InstEnv = UniqFM ClsInstEnv	-- Maps Class to instances for that class

data ClsInstEnv 
  = ClsIE [Instance]	-- The instances for a particular class, in any order
  	  Bool 		-- True <=> there is an instance of form C a b c
			-- 	If *not* then the common case of looking up
			--	(C a b c) can fail immediately

instance Outputable ClsInstEnv where
  ppr (ClsIE is b) = ptext (sLit "ClsIE") <+> ppr b <+> pprInstances is

-- INVARIANTS:
--  * The is_tvs are distinct in each Instance
--	of a ClsInstEnv (so we can safely unify them)

-- Thus, the @ClassInstEnv@ for @Eq@ might contain the following entry:
--	[a] ===> dfun_Eq_List :: forall a. Eq a => Eq [a]
-- The "a" in the pattern must be one of the forall'd variables in
-- the dfun type.

emptyInstEnv :: InstEnv
emptyInstEnv = emptyUFM

instEnvElts :: InstEnv -> [Instance]
instEnvElts ie = [elt | ClsIE elts _ <- eltsUFM ie, elt <- elts]

classInstances :: (InstEnv,InstEnv) -> Class -> [Instance]
classInstances (pkg_ie, home_ie) cls 
  = get home_ie ++ get pkg_ie
  where
    get env = case lookupUFM env cls of
		Just (ClsIE insts _) -> insts
		Nothing		     -> []

extendInstEnvList :: InstEnv -> [Instance] -> InstEnv
extendInstEnvList inst_env ispecs = foldl extendInstEnv inst_env ispecs

extendInstEnv :: InstEnv -> Instance -> InstEnv
extendInstEnv inst_env ins_item@(Instance { is_cls = cls_nm, is_tcs = mb_tcs })
  = addToUFM_C add inst_env cls_nm (ClsIE [ins_item] ins_tyvar)
  where
    add (ClsIE cur_insts cur_tyvar) _ = ClsIE (ins_item : cur_insts)
					      (ins_tyvar || cur_tyvar)
    ins_tyvar = not (any isJust mb_tcs)
\end{code}


%************************************************************************
%*									*
	Looking up an instance
%*									*
%************************************************************************

@lookupInstEnv@ looks up in a @InstEnv@, using a one-way match.  Since
the env is kept ordered, the first match must be the only one.  The
thing we are looking up can have an arbitrary "flexi" part.

\begin{code}
type InstTypes = [Either TyVar Type]
	-- Right ty	=> Instantiate with this type
	-- Left tv 	=> Instantiate with any type of this tyvar's kind

type InstMatch = (Instance, InstTypes)
\end{code}

Note [InstTypes: instantiating types]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
A successful match is an Instance, together with the types at which
	the dfun_id in the Instance should be instantiated
The instantiating types are (Mabye Type)s because the dfun
might have some tyvars that *only* appear in arguments
	dfun :: forall a b. C a b, Ord b => D [a]
When we match this against D [ty], we return the instantiating types
	[Right ty, Left b]
where the Nothing indicates that 'b' can be freely instantiated.  
(The caller instantiates it to a flexi type variable, which will presumably
 presumably later become fixed via functional dependencies.)

\begin{code}
lookupInstEnv :: (InstEnv, InstEnv) 	-- External and home package inst-env
	      -> Class -> [Type]	-- What we are looking for
	      -> ([InstMatch], 		-- Successful matches
		  [Instance],		-- These don't match but do unify
                  Bool)                 -- True if error condition caused by
                                        -- SafeHaskell condition.

-- The second component of the result pair happens when we look up
--	Foo [a]
-- in an InstEnv that has entries for
--	Foo [Int]
--	Foo [b]
-- Then which we choose would depend on the way in which 'a'
-- is instantiated.  So we report that Foo [b] is a match (mapping b->a)
-- but Foo [Int] is a unifier.  This gives the caller a better chance of
-- giving a suitable error messagen

lookupInstEnv (pkg_ie, home_ie) cls tys
  = (safe_matches, all_unifs, safe_fail)
  where
    rough_tcs  = roughMatchTcs tys
    all_tvs    = all isNothing rough_tcs
    (home_matches, home_unifs) = lookup home_ie 
    (pkg_matches,  pkg_unifs)  = lookup pkg_ie  
    all_matches = home_matches ++ pkg_matches
    all_unifs   = home_unifs   ++ pkg_unifs
    pruned_matches = foldr insert_overlapping [] all_matches
    (safe_matches, safe_fail) = if length pruned_matches == 1 
                        then check_safe (head pruned_matches) all_matches
                        else (pruned_matches, False)
	-- Even if the unifs is non-empty (an error situation)
	-- we still prune the matches, so that the error message isn't
	-- misleading (complaining of multiple matches when some should be
	-- overlapped away)

    -- SafeHaskell: We restrict code compiled in 'Safe' mode from 
    -- overriding code compiled in any other mode. The rational is
    -- that code compiled in 'Safe' mode is code that is untrusted
    -- by the ghc user. So we shouldn't let that code change the
    -- behaviour of code the user didn't compile in 'Safe' mode
    -- since thats the code they trust. So 'Safe' instances can only
    -- overlap instances from the same module. A same instance origin
    -- policy for safe compiled instances.
    check_safe match@(inst,_) others
        = case isSafeOverlap (is_flag inst) of
                -- most specific isn't from a Safe module so OK
                False -> ([match], False)
                -- otherwise we make sure it only overlaps instances from
                -- the same module
                True -> (go [] others, True)
        where
            go bad [] = match:bad
            go bad (i@(x,_):unchecked) =
                if inSameMod x
                    then go bad unchecked
                    else go (i:bad) unchecked
            
            inSameMod b =
                let na = getName $ getName inst
                    la = isInternalName na
                    nb = getName $ getName b
                    lb = isInternalName nb
                in (la && lb) || (nameModule na == nameModule nb)

    --------------
    lookup env = case lookupUFM env cls of
		   Nothing -> ([],[])	-- No instances for this class
		   Just (ClsIE insts has_tv_insts)
			| all_tvs && not has_tv_insts
			-> ([],[])	-- Short cut for common case
			-- The thing we are looking up is of form (C a b c), and
			-- the ClsIE has no instances of that form, so don't bother to search
	
			| otherwise
			-> find [] [] insts

    --------------
    lookup_tv :: TvSubst -> TyVar -> Either TyVar Type	
	-- See Note [InstTypes: instantiating types]
    lookup_tv subst tv = case lookupTyVar subst tv of
				Just ty -> Right ty
				Nothing -> Left tv

    find ms us [] = (ms, us)
    find ms us (item@(Instance { is_tcs = mb_tcs, is_tvs = tpl_tvs, 
				 is_tys = tpl_tys, is_flag = oflag,
				 is_dfun = dfun }) : rest)
	-- Fast check for no match, uses the "rough match" fields
      | instanceCantMatch rough_tcs mb_tcs
      = find ms us rest

      | Just subst <- tcMatchTys tpl_tvs tpl_tys tys
      = let 
	    (dfun_tvs, _) = tcSplitForAllTys (idType dfun)
	in 
	ASSERT( all (`elemVarSet` tpl_tvs) dfun_tvs )	-- Check invariant
 	find ((item, map (lookup_tv subst) dfun_tvs) : ms) us rest

	-- Does not match, so next check whether the things unify
	-- See Note [Overlapping instances] above
      | Incoherent _ <- oflag
      = find ms us rest

      | otherwise
      = ASSERT2( tyVarsOfTypes tys `disjointVarSet` tpl_tvs,
		 (ppr cls <+> ppr tys <+> ppr all_tvs) $$
		 (ppr dfun <+> ppr tpl_tvs <+> ppr tpl_tys)
		)
		-- Unification will break badly if the variables overlap
		-- They shouldn't because we allocate separate uniques for them
        case tcUnifyTys instanceBindFun tpl_tys tys of
	    Just _   -> find ms (item:us) rest
	    Nothing  -> find ms us	  rest

---------------
---------------
insert_overlapping :: InstMatch -> [InstMatch] -> [InstMatch]
-- Add a new solution, knocking out strictly less specific ones
insert_overlapping new_item [] = [new_item]
insert_overlapping new_item (item:items)
  | new_beats_old && old_beats_new = item : insert_overlapping new_item items
	-- Duplicate => keep both for error report
  | new_beats_old = insert_overlapping new_item items
	-- Keep new one
  | old_beats_new = item : items
	-- Keep old one
  | otherwise	  = item : insert_overlapping new_item items
	-- Keep both
  where
    new_beats_old = new_item `beats` item
    old_beats_new = item `beats` new_item

    (instA, _) `beats` (instB, _)
          = overlap_ok && 
            isJust (tcMatchTys (is_tvs instB) (is_tys instB) (is_tys instA))
                    -- A beats B if A is more specific than B,
                    -- (ie. if B can be instantiated to match A)
                    -- and overlap is permitted
          where
            -- Overlap permitted if *either* instance permits overlap
            -- This is a change (Trac #3877, Dec 10). It used to
            -- require that instB (the less specific one) permitted overlap.
            overlap_ok = case (is_flag instA, is_flag instB) of
                              (NoOverlap _, NoOverlap _) -> False
                              _                          -> True
\end{code}


%************************************************************************
%*									*
	Binding decisions
%*									*
%************************************************************************

\begin{code}
instanceBindFun :: TyVar -> BindFlag
instanceBindFun tv | isTcTyVar tv && isOverlappableTyVar tv = Skolem
                   | otherwise                              = BindMe
   -- Note [Binding when looking up instances]
\end{code}

Note [Binding when looking up instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When looking up in the instance environment, or family-instance environment,
we are careful about multiple matches, as described above in 
Note [Overlapping instances]

The key_tys can contain skolem constants, and we can guarantee that those
are never going to be instantiated to anything, so we should not involve
them in the unification test.  Example:
	class Foo a where { op :: a -> Int }
	instance Foo a => Foo [a] 	-- NB overlap
	instance Foo [Int]		-- NB overlap
	data T = forall a. Foo a => MkT a
	f :: T -> Int
	f (MkT x) = op [x,x]
The op [x,x] means we need (Foo [a]).  Without the filterVarSet we'd
complain, saying that the choice of instance depended on the instantiation
of 'a'; but of course it isn't *going* to be instantiated.

We do this only for isOverlappableTyVar skolems.  For example we reject
	g :: forall a => [a] -> Int
	g x = op x
on the grounds that the correct instance depends on the instantiation of 'a'
