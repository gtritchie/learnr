
# inline execution evaluator
inline_evaluator <- function(expr, timelimit, ...) {

  result <- NULL

  list(
    start = function() {

      # setTimeLimit -- if the timelimit is exceeeded an error will occur
      # during knit which we will catch and format within evaluate_exercise
      setTimeLimit(elapsed=timelimit, transient=TRUE);
      on.exit(setTimeLimit(cpu=Inf, elapsed=Inf, transient=FALSE), add = TRUE);

      # execute and capture result
      result <<- tryCatch(
        force(expr),
        error = function(e) {
          # TODO: could grepl the error message to determine if the error was due
          # to an exceeded timeout.
          exercise_result_error(e$message, timeout_exceeded = NA)
        }
      )
    },

    completed = function() {
      TRUE
    },

    result = function() {
      result
    }
  )
}

# forked execution evaluator
setup_forked_evaluator_factory <- function(max_forked_procs){
  running_exercises <- 0

  function(expr, timelimit, ...) {
    if (is_mac()) {
      rlang::warn("Forked evaluators may not work as expected on MacOS")
    } else if (is_windows()) {
      rlang::warn("Forked evaluators may not work as expected on Windows")
    }

    # closure object to track job, start time and result
    self <- list()

    # helper to call a hook function
    call_hook <- function(name, default = NULL) {
      hook <- getOption(paste0("tutorial.exercise.evaluator.", name))
      if (!is.null(hook)) {
        hook(self$job$pid)
      } else if (!is.null(default)) {
        default(self$job$pid)
      }
    }

    # default cleanup function
    default_cleanup <- function(pid) {
      system(paste("kill -9", pid))
    }

    list(

      start = function() {
        self$start_time <<- Sys.time()

        doStart <- function(){
          if (running_exercises >= max_forked_procs) {
            # Then we can't start this job yet.
            print("Delaying exercise execution due to forked proc limits")
            later::later(doStart, 0.1)
            return()
          }

          # increment our counter of processes
          running_exercises <<- running_exercises + 1

          self$job <<- parallel::mcparallel(mc.interactive = FALSE, {

            # close all connections
            closeAllConnections()

            # call onstart hook
            call_hook("onstart")

            # evaluate the expression
            force(expr)
          })
        }
        doStart()
      },

      completed = function() {
        if (!"start_time" %in% names(self)) {
          # Evaluation hasn't started, can't call mccollect() yet
          return(NA)
        }

        if ("result" %in% names(self)) {
          # We know the job is complete because we have a collected result
          return(TRUE)
        }

        # attempt to collect the result
        collect <- parallel::mccollect(jobs = self$job, wait = FALSE, timeout = 0.01)

        # got result
        if (!is.null(collect)) {
          # call cleanup hook
          call_hook("oncleanup", default = default_cleanup)

          # decrement our counter of processes
          running_exercises <<- running_exercises - 1

          # return result
          self$result <<- collect[[1]]

          # check if it's an error and convert it to an html error if it is
          if (inherits(self$result, "try-error")) {
            self$result <<- exercise_result_error(self$result, timeout_exceeded = FALSE)
          }

          return(TRUE)
        }

        # hit timeout
        if (difftime(Sys.time(), self$start_time, units="secs") >= timelimit) {

          # call cleanup hook
          call_hook("oncleanup", default = default_cleanup)

          # decrement our counter of processes
          running_exercises <<- running_exercises - 1

          # store error result
          self$result <<- exercise_result_timeout()
          return(TRUE)
        }

        # not yet completed
        FALSE
      },

      result = function() {
        self$result
      }
    )
  }
}

forked_evaluator_factory <- setup_forked_evaluator_factory(max_forked_procs = getOption("tutorial.max.forked.procs", Sys.getenv("TUTORIAL_MAX_FORKED_PROCS", 3)))
# Maintain for backwards-compatibility with original implementation in which
# forked_evaluator was uncapped
forked_evaluator <- setup_forked_evaluator_factory(max_forked_procs = Inf)

#' External execution evaluator
#'
#' [Lifecycle: experimental](https://www.tidyverse.org/lifecycle/#experimental)
#' @param endpoint The HTTP(S) endpoint to POST the exercises to
#' @param max_curl_conns The maximum number of simultaneous HTTP requests to the
#'   endpoint.
#' @import curl
#' @export
external_evaluator <- function(
  endpoint = getOption("tutorial.external.host", Sys.getenv("TUTORIAL_EXTERNAL_EVALUATOR_HOST", NA)),
  max_curl_conns = 50){

  internal_external_evaluator(endpoint, max_curl_conns)
}

# An internal version of external_evaluator that allows us to stub some calls
# for testing.
# Note that the cookie implementation of the external evaluator is currently
# limited. Cookies are persisted on the initialization call and reused by
# subsequent exercise evaluations. But they are NOT updated during exercise
# evaluations.
#' @importFrom promises then
#' @noRd
internal_external_evaluator <- function(
  endpoint,
  max_curl_conns,
  initiate = initiate_external_session){

  if (is.na(endpoint)){
    stop("You must specify an endpoint explicitly as a parameter, or via the `tutorial.external.host` option, or the `TUTORIAL_EXTERNAL_EVALUATOR_HOST` environment variable")
  }

  # Trim trailing slash
  endpoint <- sub("/+$", "", endpoint)

  function(expr, timelimit, exercise, session, ...) {
    result <- NULL
    pool <- curl::new_pool(total_con = max_curl_conns, host_con = max_curl_conns)

    list(
      start = function() {

        # The actual workhorse here -- called once we have a session ID on the external evaluator
        submit_req <- function(sess_id, cookiejar){
          # Work around a few edge cases on the exercise that don't serialize well
          if (identical(exercise$options$exercise.checker, "NULL")){
            exercise$options$exercise.checker <- c()
          }

          json <- jsonlite::toJSON(exercise, auto_unbox = TRUE, null = "null", force = TRUE)
          if (
            identical(tolower(Sys.getenv("TUTORIAL_DEBUG_EXTERNAL_EVALUATOR_EVENT_SUBMISSION", "")), "true") ||
            "submission" %in% getOption("tutorial.debug.external_evaluator_event", "")
          ) {
            event_trigger(session, "external_evaluator_submission", as.character(json))
          }

          if (is.null(exercise$options$exercise.timelimit) || exercise$options$exercise.timelimit == 0){
            timeout_s <- 30 * 1000
          } else {
            timeout_s <- exercise$options$exercise.timelimit * 1000
          }

          # Create curl request
          handle <- curl::new_handle(customrequest = "POST",
                                     copypostfields = json,
                                     # add 15 seconds for application startup
                                     timeout_ms = timeout_s + 15000,
                                     cookiefile=cookiejar)
          curl::handle_setheaders(handle, "Content-Type" = "application/json")

          url <- paste0(endpoint, "/learnr/", sess_id)

          # Track whether or not the current request is still active.
          # We cannot use multi_run()$pending because it waits for ALL pending
          # requests in the pool to resolve.
          pending <- TRUE

          done_cb <- function(res){
            pending <<- FALSE

            tryCatch({
              if (res$status != 200){
                fail_cb(response_to_error(res))
                return()
              }

              r <- rawToChar(res$content)
              if (
                identical(tolower(Sys.getenv("TUTORIAL_DEBUG_EXTERNAL_EVALUATOR_EVENT_RESULT", "")), "true") ||
                "result" %in% getOption("tutorial.debug.external_evaluator_event", "")
              ) {
                event_trigger(session, "external_evaluator_result", r)
              }

              p <- jsonlite::fromJSON(r)
              p$html_output <- htmltools::HTML(p$html_output)
              result <<- p
            }, error = function(e){
              print(e)
              fail_cb(response_to_error(res))
            })
          }

          fail_cb <- function(err){
            pending <<- FALSE

            print("Error submitting external exercise:")
            print(err)
            result <<- exercise_result_error("Error submitting external exercise. Please try again later")
          }

          curl::curl_fetch_multi(url, handle = handle, done = done_cb, fail = fail_cb, pool = pool)

          poll <- function(){
            curl::multi_run(timeout = 0, pool = pool)
            if (pending){
              later::later(poll, delay = 0.1)
            }
          }
          poll()
        }

        # Initiate a session
        if (is.null(session$userData$.external_evaluator_session_id)){
          session$userData$.external_evaluator_session_id <-
            initiate(pool, paste0(endpoint, "/learnr/"), exercise$global_setup) %>%
            then(onFulfilled = function(extsess){
              session$onSessionEnded(function(){
                # Cleanup session cookiefile
                # Because of https://github.com/rstudio/shiny/pull/2757, we can't
                # trust that the reactive context will be provided here. So just
                # grab objects from the closure.
                unlink(extsess$cookieFile)
              })
              extsess
            })
        }

        session$userData$.external_evaluator_session_id %>% then(
          onFulfilled = function(extsess){
            submit_req(extsess$id, extsess$cookieFile)
          },
          onRejected = function(err){
            print(err)
            result <<- exercise_result_error("Error initiating session for external requests. Please try again later")
          }
        )
      },

      completed = function() {
        !is.null(result)
      },

      result = function() {
        tryCatch({
          result$feedback <- tryCatch(
            feedback_validated(result$feedback),
            error = function(e) {
              warning(e$message)
              NULL
            }
          )
          do.call(exercise_result, result)
        }, error = function(e) {
          exercise_result_error_internal(
            exercise = exercise,
            error = e,
            task_internal = "converting result from external evaluator into a learnr exercise result"
          )
        })
      }
    )
  }
}

#' Returns a promise representing a a unique session
#' @param pool the curl pool to use for this request
#' @param url The URL to POST to to get a session
#' @param callback The callback to invoke on success. Provides one parameter:
#'   the session ID
#' @param err_callback The callback to invoke on error. Provides one parameter:
#'   the err'ing response
#' @param cookieFile The path to a file into which cookies should be written
#' @return a promise that resolves to a list of (id = `<sessionID>`, cookieFile = `<path to cookie file>`).
#' @importFrom promises promise
#' @importFrom promises %>%
#' @noRd
initiate_external_session <- function(pool, url, global_setup, retry_count = 0){
  promises::promise(function(resolve, reject){
    json <- jsonlite::toJSON(list(global_setup = global_setup), auto_unbox = TRUE, null = "null")
    handle <- curl::new_handle(customrequest = "POST",
                               copypostfields = json)

    # Track whether or not the current request is still active.
    # We cannot use multi_run()$pending because it waits for ALL pending
    # requests in the pool to resolve.
    pending <- TRUE

    err_cb <- function(res){
      pending <<- FALSE

      # may just have hit a temporarily overloaded server. Retry
      if (res$status == 503 && retry_count < 2) { # three total tries
        resolve(initiate_external_session(pool, url, global_setup, retry_count+1))
        return()
      } else {
        # invoke the given error callback
        reject(response_to_error(res))
        return()
      }
    }

    done_cb <- function(res){
      pending <<- FALSE

      id <- NULL
      failed <- FALSE

      if (res$status != 200){
        reject(response_to_error(res))
        return()
      }

      tryCatch({
        r <- rawToChar(res$content)
        p <- jsonlite::fromJSON(r)
        id <- p$id
      }, error = function(e) {
        print(e)
        reject(response_to_error(res))
        return()
      })

      cookies <- handle_cookies(handle)
      cookieFile <- tempfile("cookies")
      write_cookies(cookies, cookieFile)
      resolve(list(id = id, cookieFile = cookieFile))
    }

    curl::curl_fetch_multi(url, handle = handle, done = done_cb, fail = reject, pool = pool)

    poll <- function(){
      curl::multi_run(timeout = 0, pool = pool)
      if (pending){
        later::later(poll, delay = 0.1)
      }
    }
    poll()
  })
}

response_to_error <- function(res){
  headers <- res$headers
  if (is.raw(headers)){
    headers <- rawToChar(headers)
  }

  content <- res$content
  if (is.raw(content)){
    content <- rawToChar(content)
  }

  list(
    url = res$url,
    status_code = res$status_code,
    headers = headers,
    content = content
  )
}

# Writes out cookies into the Netscape format that curl supports
# We write these files ourselves because the curl package doesn't provide the
# necessary hooks to do this more cleanly. There are two options that were
# considered:
#  1. As documented, cookies are persisted on R curl handles. So if you reuse and
#     reset a single curl handle, you don't have to worry about carrying around
#     the cookies. Unfortunately, we want to create connections async and in
#     parallel, and a single curl handle can't be reused like that.
#  2. We could use the libcurl COOKIEFILE and COOKIEJAR options. Unfortunately,
#     we don't have tight guarantees about exactly when a curl handle is going to
#     be closed. In interactive use, it worked fine but programatically we often
#     went to read the file before it had been written. I think we're in a race
#     against the R garbage collector if we use this approach.
# So we settled on this approach -- persisting the cookies off the connection
# ourselves in a format that can be read in by curl using the COOKIEFILE option.
#' @importFrom utils write.table
write_cookies <- function(cookies, cookieFile){
  cookies$expiration <- as.numeric(cookies$expiration)
  cookies$expiration[is.infinite(cookies$expiration) | is.na(cookies$expiration)] <- 0
  cookies$expiration <- as.integer(cookies$expiration)
  write.table(cookies, cookieFile, row.names=FALSE, col.names=FALSE, sep="\t", quote = FALSE)
}
