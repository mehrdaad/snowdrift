{-# LANGUAGE TupleSections #-}

module Handler.Discussion where

import Import

import Data.Time

import Data.Tree

import qualified Data.Foldable as F
import qualified Data.Map as M
import qualified Data.Set as S
import qualified Data.List as L
import qualified Data.Text as T

import Model.AnnotatedTag
import Model.User

import Widgets.Markdown
import Widgets.Preview
import Widgets.Tag
import Widgets.Time

import Yesod.Markdown
import Model.Markdown


renderComment :: UserId -> Text -> Text -> M.Map UserId (Entity User) -> Int -> Int
    -> [CommentRetraction] -> M.Map CommentId CommentRetraction -> Bool -> Map TagId Tag -> Tree (Entity Comment) -> Maybe Widget -> Widget

renderComment viewer_id project_handle target users max_depth depth earlier_retractions retraction_map show_actions tag_map tree mcomment_form = do
    maybe_route <- handlerToWidget getCurrentRoute
    (comment_form, _) <- handlerToWidget $ generateFormPost $ commentForm Nothing Nothing

    let Entity comment_id comment = rootLabel tree
        children = subForest tree

        Entity user_id user = users M.! commentUser comment
        author_name = userPrintName (Entity user_id user)
        comment_time = renderTime (commentCreatedTs comment)
        unapproved = not $ isJust $ commentModeratedTs comment

        top_level = (commentDepth comment == 0)
        even_depth = not top_level && commentDepth comment `mod` 2 == 1
        odd_depth = not top_level && not even_depth

        maybe_retraction = M.lookup comment_id retraction_map
        empty_list = []

    tags <- fmap (L.sortBy (compare `on` atName)) $ handlerToWidget $ do
        comment_tags <- runDB $ select $ from $ \ comment_tag -> do
            where_ $ comment_tag ^. CommentTagComment ==. val comment_id
            return comment_tag

        annotateCommentTags tag_map project_handle target comment_id $ map entityVal comment_tags

    $(widgetFile "comment_body")

disabledCommentForm :: Form Markdown
disabledCommentForm = renderBootstrap3 $ areq snowdriftMarkdownField ("Reply" { fsAttrs = [("disabled",""), ("class","form-control")] }) Nothing

commentForm :: Maybe CommentId -> Maybe Markdown -> Form (Maybe CommentId, Markdown)
commentForm parent content = renderBootstrap3
    $ (,)
        <$> aopt' hiddenField "" (Just parent)
        <*> areq' snowdriftMarkdownField (if parent == Nothing then "Comment" else "Reply") content

getOldApproveCommentR :: Text -> Text -> CommentId -> Handler Html
getOldApproveCommentR project_handle target comment_id = redirect $ ApproveCommentR project_handle target comment_id

getApproveCommentR :: Text -> Text -> CommentId -> Handler Html
getApproveCommentR project_handle target comment_id = do
    user_id <- requireAuthId

    Entity project_id _ <- runDB $ getBy404 $ UniqueProjectHandle project_handle
    Entity page_id page <- runDB $ getBy404 $ UniqueWikiTarget project_id target

    comment_page <- fmap (wikiPageCommentPage . entityVal) $ runDB $ getBy404 $ UniqueWikiPageComment comment_id

    when (comment_page /= page_id) $ error "comment does not match page"
    when (wikiPageProject page /= project_id) $ error "comment does not match project"

    moderator <- runDB $ isProjectModerator project_handle user_id

    when (not moderator) $ error "you must be a moderator to approve posts"

    defaultLayout [whamlet|
        <form method="POST">
            <input type=submit value="approve post">
    |]


postOldApproveCommentR :: Text -> Text -> CommentId -> Handler Html
postOldApproveCommentR = postApproveCommentR

postApproveCommentR :: Text -> Text -> CommentId -> Handler Html
postApproveCommentR project_handle target comment_id = do
    user_id <- requireAuthId

    now <- liftIO getCurrentTime

    Entity project_id _ <- runDB $ getBy404 $ UniqueProjectHandle project_handle
    Entity page_id page <- runDB $ getBy404 $ UniqueWikiTarget project_id target

    comment_page <- fmap (wikiPageCommentPage . entityVal) $ runDB $ getBy404 $ UniqueWikiPageComment comment_id

    when (comment_page /= page_id) $ error "comment does not match page"
    when (wikiPageProject page /= project_id) $ error "comment does not match project"

    moderator <- runDB $ isProjectModerator project_handle user_id

    when (not moderator) $ error "you must be a moderator to approve posts"

    runDB $ update $ \ c -> do
        set c
            [ CommentModeratedTs =. val (Just now)
            , CommentModeratedBy =. val (Just user_id)
            ]

        where_ $ c ^. CommentId ==. val comment_id

    addAlert "success" "comment approved"

    redirect $ DiscussCommentR project_handle target comment_id


retractForm :: Maybe Markdown -> Form Markdown
retractForm reason = renderBootstrap3 $ areq snowdriftMarkdownField "Retraction reason:" reason



countReplies :: [Tree a] -> Int
countReplies = sum . map (F.sum . fmap (const 1))


getOldRetractCommentR :: Text -> Text -> CommentId -> Handler Html
getOldRetractCommentR project_handle target comment_id = redirect $ RetractCommentR project_handle target comment_id

getRetractCommentR :: Text -> Text -> CommentId -> Handler Html
getRetractCommentR project_handle target comment_id = do
    Entity user_id user <- requireAuth
    comment <- runDB $ get404 comment_id
    when (commentUser comment /= user_id) $ permissionDenied "You can only retract your own comments."

    earlier_retractions <- runDB $
        case commentParent comment of
            Just parent_id -> do
                ancestors <- do
                    comment_ancestor_entities <- select $ from $ \ comment_ancestor -> do
                        where_ ( comment_ancestor ^. CommentAncestorComment ==. val parent_id )
                        return comment_ancestor

                    return . (parent_id :) . map (commentAncestorAncestor . entityVal) $ comment_ancestor_entities

                fmap (map entityVal) $ select $ from $ \ comment_retraction -> do
                    where_ ( comment_retraction ^. CommentRetractionComment `in_` valList ancestors )
                    return comment_retraction

            Nothing -> return []

    tags <- runDB $ select $ from $ \ (comment_tag `InnerJoin` tag) -> do
        on_ $ comment_tag ^. CommentTagTag ==. tag ^. TagId
        where_ $ comment_tag ^. CommentTagComment ==. val comment_id
        return tag

    let tag_map = M.fromList $ entityPairs tags

    (retract_form, _) <- generateFormPost $ retractForm Nothing

    let rendered_comment = renderDiscussComment user_id project_handle target False (return ()) (Entity comment_id comment) [] (M.singleton user_id $ Entity user_id user) earlier_retractions M.empty False tag_map

    defaultLayout $ [whamlet|
        ^{rendered_comment}
        <form method="POST">
            ^{retract_form}
            <input type="submit" name="mode" value="preview retraction">
    |]


postOldRetractCommentR :: Text -> Text -> CommentId -> Handler Html
postOldRetractCommentR = postRetractCommentR

postRetractCommentR :: Text -> Text -> CommentId -> Handler Html
postRetractCommentR project_handle target comment_id = do
    Entity user_id user <- requireAuth
    comment <- runDB $ get404 comment_id
    when (commentUser comment /= user_id) $ permissionDenied "You can only retract your own comments."

    ((result, _), _) <- runFormPost $ retractForm Nothing

    case result of
        FormSuccess reason -> do
            earlier_retractions <- runDB $
                case commentParent comment of
                    Just parent_id -> do
                        ancestors <- do
                            comment_ancestor_entities <- select $ from $ \ comment_ancestor -> do
                                where_ ( comment_ancestor ^. CommentAncestorComment ==. val parent_id )
                                return comment_ancestor

                            return . (parent_id :) . map (commentAncestorAncestor . entityVal) $ comment_ancestor_entities
                        map entityVal <$> selectList [ CommentRetractionComment <-. ancestors ] []

                    Nothing -> return []

            let action :: Text = "retract"
            mode <- lookupPostParam "mode"
            case mode of
                Just "preview retraction" -> do
                    (form, _) <- generateFormPost $ retractForm (Just reason)

                    tags <- runDB $ select $ from $ \ (comment_tag `InnerJoin` tag) -> do
                        on_ $ comment_tag ^. CommentTagTag ==. tag ^. TagId
                        where_ $ comment_tag ^. CommentTagComment ==. val comment_id
                        return tag

                    let tag_map = M.fromList $ entityPairs tags
                        soon = UTCTime (ModifiedJulianDay 0) 0
                        retraction = CommentRetraction soon reason comment_id
                        comment_entity = Entity comment_id comment
                        users = M.singleton user_id $ Entity user_id user
                        retractions = M.singleton comment_id retraction

                    defaultLayout $ renderPreview form action $ renderDiscussComment user_id project_handle target False (return ()) comment_entity [] users earlier_retractions retractions False tag_map


                Just a | a == action -> do
                    now <- liftIO getCurrentTime
                    _ <- runDB $ insert $ CommentRetraction now reason comment_id

                    redirect $ DiscussCommentR project_handle target comment_id

                _ -> error "Error: unrecognized mode."
        _ -> error "Error when submitting form."


buildCommentTree :: Entity Comment -> [ Entity Comment ] -> Tree (Entity Comment)
buildCommentTree root rest =
    let treeOfList (node, items) =
            let has_parent p = (== Just (entityKey p)) . commentParent . entityVal
                list = dropWhile (not . has_parent node) items
                (children, rest') = span (has_parent node) list
                items' = map (, rest') children
             in (node, items')

     in unfoldTree treeOfList (root, rest)


getOldDiscussWikiR :: Text -> Text -> Handler Html
getOldDiscussWikiR project_handle target = redirect $ DiscussWikiR project_handle target

getDiscussWikiR :: Text -> Text -> Handler Html
getDiscussWikiR project_handle target = do
    Entity user_id user <- requireAuth
    Entity page_id page  <- runDB $ do
        Entity project_id _ <- getBy404 $ UniqueProjectHandle project_handle
        getBy404 $ UniqueWikiTarget project_id target

    affiliated <- runDB $ (||)
            <$> isProjectAffiliated project_handle user_id
            <*> isProjectAdmin "snowdrift" user_id

    moderator <- runDB $ isProjectModerator project_handle user_id

    (roots, rest, users, retraction_map) <- runDB $ do
        roots <- select $ from $ \ (comment `InnerJoin` wiki_page_comment) -> do
            on_ $ comment ^. CommentId ==. wiki_page_comment ^. WikiPageCommentComment
            where_ $ foldl1 (&&.) $ catMaybes
                [ Just $ wiki_page_comment ^. WikiPageCommentPage ==. val page_id
                , Just $ isNothing $ comment ^. CommentParent
                , if moderator then Nothing else Just $ not_ $ isNothing $ comment ^. CommentModeratedTs
                ]

            orderBy [asc (comment ^. CommentCreatedTs)]
            return comment

        rest <- select $ from $ \ (comment `InnerJoin` wiki_page_comment) -> do
            on_ $ comment ^. CommentId ==. wiki_page_comment ^. WikiPageCommentComment
            where_ $ foldl1 (&&.) $ catMaybes
                [ Just $ wiki_page_comment ^. WikiPageCommentPage ==. val page_id
                , Just $ not_ $ isNothing $ comment ^. CommentParent
                , if moderator then Nothing else Just $ not_ $ isNothing $ comment ^. CommentModeratedTs
                ]

            orderBy [asc (comment ^. CommentParent), asc (comment ^. CommentCreatedTs)]
            return comment

        let get_user_ids = S.fromList . map (commentUser . entityVal) . F.toList
            user_id_list = S.toList $ get_user_ids roots `S.union` get_user_ids rest

        user_entities <- selectList [ UserId <-. user_id_list ] []

        let users = M.fromList $ map (entityKey &&& id) user_entities

        retraction_map <- M.fromList . map ((commentRetractionComment &&& id) . entityVal) <$> selectList [ CommentRetractionComment <-. map entityKey (roots ++ rest) ] []
        return (roots, rest, users, retraction_map)

    tags <- runDB $ select $ from $ return

    let tag_map = M.fromList $ entityPairs tags
        comments = forM_ roots $ \ root ->
            renderComment user_id project_handle target users 10 0 [] retraction_map True tag_map (buildCommentTree root rest) Nothing

    (comment_form, _) <- generateFormPost $ commentForm Nothing Nothing

    let has_comments = not $ null roots

    defaultLayout $(widgetFile "wiki_discuss")


getOldDiscussCommentR :: Text -> Text -> CommentId -> Handler Html
getOldDiscussCommentR project_handle target comment_id = redirect $ DiscussCommentR project_handle target comment_id

getDiscussCommentR :: Text -> Text -> CommentId -> Handler Html
getDiscussCommentR =
    getDiscussCommentR' False

getReplyCommentR :: Text -> Text -> CommentId -> Handler Html
getReplyCommentR =
    getDiscussCommentR' True

getDiscussCommentR' :: Bool -> Text -> Text -> CommentId -> Handler Html
getDiscussCommentR' show_reply project_handle target comment_id = do
    Entity viewer_id _ <- requireAuth
    Entity page_id _  <- runDB $ do
        Entity project_id _ <- getBy404 $ UniqueProjectHandle project_handle
        getBy404 $ UniqueWikiTarget project_id target

    (root, rest, users, earlier_retractions, retraction_map) <- runDB $ do
        root <- get404 comment_id
        root_wiki_page <- fmap (wikiPageCommentPage . entityVal) $ getBy404 $ UniqueWikiPageComment comment_id

        when (root_wiki_page /= page_id) $ error "Selected comment does not match selected page"

        subtree <- select $ from $ \ comment -> do
            where_ ( comment ^. CommentAncestorAncestor ==. val comment_id )
            return comment

        rest <- select $ from $ \ (comment `InnerJoin` wiki_page_comment) -> do
            on_ $ comment ^. CommentId ==. wiki_page_comment ^. WikiPageCommentComment
            where_ $ wiki_page_comment ^. WikiPageCommentPage ==. val page_id
                    &&. comment ^. CommentId >. val comment_id
                    &&. comment ^. CommentId `in_` valList (map (commentAncestorComment . entityVal) subtree)
            orderBy [asc (comment ^. CommentParent), asc (comment ^. CommentCreatedTs)]
            return comment

        let get_user_ids = S.fromList . map (commentUser . entityVal) . F.toList
            user_id_list = S.toList $ S.insert (commentUser root) $ get_user_ids rest

        user_entities <- select $ from $ \ user -> do
            where_ ( user ^. UserId `in_` valList user_id_list )
            return user

        let users = M.fromList $ map (entityKey &&& id) user_entities

        earlier_retractions <- fmap (map entityVal) $ select $ from $ \ (comment_ancestor `InnerJoin` retraction) -> do
            on_ (comment_ancestor ^. CommentAncestorAncestor ==. retraction ^. CommentRetractionComment)
            where_ ( comment_ancestor ^. CommentAncestorComment ==. val comment_id )
            return retraction

        retraction_map <- fmap (M.fromList . map ((commentRetractionComment &&& id) . entityVal)) $ select $ from $ \ retraction -> do
            where_ ( retraction ^. CommentRetractionComment `in_` valList (comment_id : map entityKey rest) )
            return retraction

        return (root, rest, users, earlier_retractions, retraction_map)

    (comment_form, _) <- generateFormPost $ commentForm (Just comment_id) Nothing

    tags <- runDB $ select $ from $ return

    let tag_map = M.fromList $ entityPairs tags

    defaultLayout $ renderDiscussComment viewer_id project_handle target show_reply comment_form (Entity comment_id root) rest users earlier_retractions retraction_map True tag_map


renderDiscussComment :: UserId -> Text -> Text -> Bool -> Widget
    -> Entity Comment -> [Entity Comment]
    -> M.Map UserId (Entity User)
    -> [CommentRetraction]
    -> M.Map CommentId CommentRetraction
    -> Bool -> M.Map TagId Tag -> Widget

renderDiscussComment viewer_id project_handle target show_reply comment_form root rest users earlier_retractions retraction_map show_actions tag_map = do
    let tree = buildCommentTree root rest
        comment = renderComment viewer_id project_handle target users 1 0 earlier_retractions retraction_map show_actions tag_map tree mcomment_form
        mcomment_form =
            if show_reply
                then Just comment_form
                else Nothing

    $(widgetFile "comment")


postOldDiscussWikiR :: Text -> Text -> Handler Html
postOldDiscussWikiR = postDiscussWikiR

postDiscussWikiR :: Text -> Text -> Handler Html
postDiscussWikiR project_handle target = do
    Entity user_id user <- requireAuth
    Entity page_id _ <- runDB $ do
        Entity project_id _ <- getBy404 $ UniqueProjectHandle project_handle
        getBy404 $ UniqueWikiTarget project_id target


    let established = isJust $ userEstablishedTs user

    now <- liftIO getCurrentTime

    ((result, _), _) <- runFormPost $ commentForm Nothing Nothing

    case result of
        FormSuccess (maybe_parent_id, text) -> do
            depth <- case maybe_parent_id of
                Just parent_id -> do
                    Just parent <- runDB $ get parent_id
                    return $ (+1) $ commentDepth parent
                _ -> return 0

            mode <- lookupPostParam "mode"

            let action :: Text = "post"

            case mode of
                Just "preview" -> do
                    earlier_retractions <- runDB $
                        case maybe_parent_id of
                            Just parent_id -> do
                                ancestors <- fmap ((parent_id :) . map (commentAncestorAncestor . entityVal)) $ select $ from $ \ ancestor -> do
                                    where_ ( ancestor ^. CommentAncestorComment ==. val parent_id )
                                    return ancestor

                                fmap (map entityVal) $ select $ from $ \ retraction -> do
                                    where_ ( retraction ^. CommentRetractionComment `in_` valList ancestors )
                                    return retraction

                            Nothing -> return []

                    tags <- runDB $ select $ from $ return

                    let tag_map = M.fromList $ entityPairs tags

                    (form, _) <- generateFormPost $ commentForm maybe_parent_id (Just text)

                    let comment = Entity (Key $ PersistInt64 0) $ Comment now Nothing Nothing maybe_parent_id user_id text depth
                        user_map = M.singleton user_id $ Entity user_id user
                        rendered_comment = renderDiscussComment user_id project_handle target False (return ()) comment [] user_map earlier_retractions M.empty False tag_map

                    defaultLayout $ renderPreview form action rendered_comment


                Just x | x == action -> do
                    runDB $ do
                        comment_id <- insert $ Comment now
                            (if established then Just now else Nothing)
                            (if established then Just user_id else Nothing)
                            maybe_parent_id user_id text depth

                        void $ insert $ WikiPageComment comment_id page_id

                        let content = T.lines $ (\ (Markdown str) -> str) text
                            tickets = map T.strip $ mapMaybe (T.stripPrefix "ticket:") content
                            tags = map T.strip $ mconcat $ map (T.splitOn ",") $ mapMaybe (T.stripPrefix "tags:") content

                        forM_ tickets $ \ ticket -> insert $ Ticket now now ticket comment_id
                        forM_ tags $ \ tag -> do
                            tag_id <- fmap (either entityKey id) $ insertBy $ Tag tag
                            insert $ CommentTag comment_id tag_id user_id 1

                        let getParentAncestors parent_id = do
                                comment_ancestor_entities <- select $ from $ \ comment_ancestor -> do
                                    where_ ( comment_ancestor ^. CommentAncestorComment ==. val parent_id )
                                    return comment_ancestor

                                let ancestors = map (commentAncestorAncestor . entityVal) comment_ancestor_entities
                                return $ parent_id : ancestors

                        ancestors <- maybe (return []) getParentAncestors maybe_parent_id

                        forM_ ancestors $ \ ancestor_id -> insert $ CommentAncestor comment_id ancestor_id

                        let selectAncestors = subList_select $ from $ \ ancestor -> do
                            where_ $ ancestor ^. CommentAncestorComment ==. val comment_id
                            return $ ancestor ^. CommentAncestorAncestor

                        update $ \ ticket -> do
                            set ticket [ TicketUpdatedTs =. val now ]
                            where_ $ ticket ^. TicketComment `in_` selectAncestors


                    addAlert "success" $ if established then "comment posted" else "comment submitted for moderation"
                    redirect $ maybe (DiscussWikiR project_handle target) (DiscussCommentR project_handle target) maybe_parent_id

                _ -> error "unrecognized mode"

        FormMissing -> error "Form missing."
        FormFailure msgs -> error $ "Error submitting form: " ++ T.unpack (T.intercalate "\n" msgs)


getOldNewDiscussWikiR :: Text -> Text -> Handler Html
getOldNewDiscussWikiR project_handle target = redirect $ NewDiscussWikiR project_handle target

getNewDiscussWikiR :: Text -> Text -> Handler Html
getNewDiscussWikiR project_handle target = do
    Entity user_id user <- requireAuth
    Entity page_id page  <- runDB $ do
        Entity project_id _ <- getBy404 $ UniqueProjectHandle project_handle
        getBy404 $ UniqueWikiTarget project_id target

    affiliated <- runDB $ (||)
            <$> isProjectAffiliated project_handle user_id
            <*> isProjectAdmin "snowdrift" user_id

    (comment_form, _) <- generateFormPost $ commentForm Nothing Nothing

    defaultLayout $(widgetFile "wiki_discuss_new")

postOldNewDiscussWikiR :: Text -> Text -> Handler Html
postOldNewDiscussWikiR = postDiscussWikiR

postNewDiscussWikiR :: Text -> Text -> Handler Html
postNewDiscussWikiR = postDiscussWikiR


getOldWikiNewCommentsR :: Text -> Handler Html
getOldWikiNewCommentsR project_handle = redirect $ WikiNewCommentsR project_handle

getWikiNewCommentsR :: Text -> Handler Html
getWikiNewCommentsR project_handle = do
    Entity viewer_id viewer <- requireAuth

    maybe_from <- fmap (Key . PersistInt64 . read . T.unpack) <$> lookupGetParam "from"

    now <- liftIO getCurrentTime

    Entity project_id project <- runDB $ getBy404 $ UniqueProjectHandle project_handle

    tags <- runDB $ select $ from $ return

    let tag_map = M.fromList $ entityPairs tags

    (comments, pages, users, retraction_map) <- runDB $ do
        unfiltered_pages <- select $ from $ \ page -> do
            where_ $ page ^. WikiPageProject ==. val project_id
            return page

        let pages = M.fromList $ map (entityKey &&& id) $ {- TODO filter ((userRole viewer >=) . wikiPageCanViewMeta . entityVal) -} unfiltered_pages


        let apply_offset comment = maybe id (\ from_comment rest -> comment ^. CommentId >=. val from_comment &&. rest) maybe_from

        comments <- select $ from $ \ (comment `InnerJoin` wiki_page_comment) -> do
            on_ $ comment ^. CommentId ==. wiki_page_comment ^. WikiPageCommentComment
            where_ $ apply_offset comment $ wiki_page_comment ^. WikiPageCommentPage `in_` valList (M.keys pages)
            orderBy [ desc (comment ^. CommentId) ]
            limit 50
            return comment

        let user_ids = S.toList $ S.fromList $ map (commentUser . entityVal) comments
        users <- fmap (M.fromList . map (entityKey &&& id)) $ select $ from $ \ user -> do
            where_ ( user ^. UserId `in_` valList user_ids )
            return user

        retraction_map <- do
            retractions <- select $ from $ \ comment_retraction -> do
                where_ ( comment_retraction ^. CommentRetractionComment `in_` valList (map entityKey comments) )
                return comment_retraction

            return . M.fromList . map ((commentRetractionComment &&& id) . entityVal) $ retractions

        return (comments, pages, users, retraction_map)

    let PersistInt64 to = unKey $ minimum (map entityKey comments)
        rendered_comments =
            if null comments
             then [whamlet|no new comments|]
             else forM_ comments $ \ (Entity comment_id comment) -> do
                earlier_retractions <- handlerToWidget $ runDB $ do
                    ancestors <- select $ from $ \ comment_ancestor -> do
                        where_ ( comment_ancestor ^. CommentAncestorComment ==. val comment_id )
                        return comment_ancestor

                    fmap (map entityVal) $ select $ from $ \ comment_retraction -> do
                        where_ ( comment_retraction ^. CommentRetractionComment `in_` valList (map (commentAncestorAncestor . entityVal) ancestors))
                        orderBy [ asc (comment_retraction ^. CommentRetractionComment) ]
                        return comment_retraction

                [Value target] <- handlerToWidget $ runDB $ select $ from $ \ (page `InnerJoin` wiki_page_comment) -> do
                    on_ $ wiki_page_comment ^. WikiPageCommentPage ==. page ^. WikiPageId
                    where_ $ wiki_page_comment ^. WikiPageCommentComment ==. val comment_id
                    return $ page ^. WikiPageTarget

                let rendered_comment = renderComment viewer_id project_handle target users 1 0 earlier_retractions retraction_map True tag_map (Node (Entity comment_id comment) []) Nothing

                [whamlet|$newline never
                    <div .row>
                        <div .col-md-9>
                            On #
                            <a href="@{WikiR project_handle target}">
                                #{target}
                            :
                            ^{rendered_comment}
                |]

    runDB $ update $ \ user -> do
        set user [ UserReadComments =. val now ]
        where_ ( user ^. UserId ==. val viewer_id )

    defaultLayout $(widgetFile "wiki_new_comments")

