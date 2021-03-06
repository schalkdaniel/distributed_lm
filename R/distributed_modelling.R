# ========================================================================================== #
#                                                                                            #
#                      Distributed Learning With Multiple Data Sources                       # 
#                                                                                            #
# ========================================================================================== #

#' Initialize a Distributed Model
#' 
#' This function creates the files and file system required to train a linear model in a 
#' distributed fashion.
#' 
#' @param formula [\code{formula}]\cr
#'   Formula analog to the formula call in \code{lm}.
#' @param model [\code{character(1)}]\cr
#'   Character indicating the model we want to use.
#' @param optimizer [\code{character(1)}]\cr
#'   Character indicating which optimizer we want to use. 
#' @param out_dir [\code{character(1)}]\cr
#'   Direction for the output files.
#' @param files [\code{character}]\cr
#'   Vector of file destinations. Each element must point to one dataset.
#' @param epochs [\code{integer(1)}]\cr
#'   Number of maximal iterations. Could be less if the "epsilon criteria" is hit.
#' @param learning_rate [\code{numeric(1)}]\cr
#'   The step size used for gradient descent. Note: If the mse is not improving the step size
#'   is shrinked by 20 percent.
#' @param mse_eps [\code{numeric(1)}]\cr
#'   Relativ improvement of the MSE. If this boundary is undershot, then the algorithm stops.
#' @param save_all [\code{logical(1)}]\cr
#'   If set to TRUE, all updates are stored within the out_dir.
#' @param file_reader [\code{function}]\cr
#'   Function to read the datasets specified in files.
#' @param overwrite [\code{logical(1)}]\cr
#'   Flag to specify whether to overwrite an existing registry and model or not.
#' @return Character of the file directory for local files.
initializeDistributedModel = function (formula, model = "LinearModel", optimizer = "gradientDescent", out_dir = getwd(), 
	files, epochs, learning_rate, mse_eps, save_all = FALSE, file_reader, overwrite = FALSE)
{
	registry = list(file_names = files, model = model, optimizer = optimizer, epochs = epochs, mse_eps = mse_eps, actual_iteration = 0,
		formula = formula, file_reader = file_reader, learning_rate = learning_rate, save_all = FALSE)
	
	file_dir = paste0(out_dir, "/train_files")
	if (overwrite) {
		if (dir.exists(file_dir)) { 
			unlink(file_dir, recursive = TRUE) 
		} else {
			warning("Nothing to overwrite, ", file_dir, " does not exist.")
		}
	}
	if (! dir.exists(file_dir)) {
		dir.create(file_dir)
	} else {
		warning(file_dir, " already exists.")
	}
	regis_dir = paste0(file_dir, "/registry.rds")
	if (file.exists(regis_dir)) {
		stop(file_dir, " already contains a registry.rds file. To overwrite this file remove it first or set 'overwrite = TRUE'.")
	} else {
		save(list = "registry", file = regis_dir)
	}
	model_dir = paste0(file_dir, "/model.rds")
	if (file.exists(model_dir)) {
		stop(model_dir, " already contains a model.rds file. To overwrite this file remove it first or set 'overwrite = TRUE'.")
	} else {
		model = list(mse_average = 0, done = FALSE)
		save(list = "model", file = model_dir)
	}
	return (file_dir)
}

#' Train Distributed Model
#' 
#' This function conducts a specific number of epochs on the local machine. Therefore, the function reads in the available
#' datasets and runs a fixed number of Gradient Descent steps. 
#' 
#' @param regis_dir [\code{character(1)}]\cr
#'   Direction for the output files.
#' @param silent [\code{logical(1)}]\cr
#' @param epochs_at_once [\code{integer(1)}]\cr
trainDistributedModel = function (regis_dir, silent = FALSE, epochs_at_once = 1L)
{
	load(file = paste0(regis_dir, "/registry.rds"))
	load(file = paste0(regis_dir, "/model.rds"))

	actual_iteration = registry[["actual_iteration"]]
	actual_state     = paste0(regis_dir, "/iter", actual_iteration, ".rds")

	if (! model[["done"]]) {

		if (! file.exists(actual_state)) {

			if (! silent) message("\nEntering iteration ", actual_iteration, "\n")

				snapshot = list()
			save(list = "snapshot", file = actual_state)
		} else {
			load(file = actual_state)
		}
		# Check if all files are already used for an update. If true make a final gradient descent step by
		# averaging the gradients:
		if (all(registry[["file_names"]] %in% names(snapshot))) {

			mse_old = model[["mse_average"]]

			final_gradient = rowMeans(as.data.frame(lapply(snapshot, function (x) x[["update_cum"]])))
			model[["beta"]] = model[["beta"]] + final_gradient
			model[["mse_average"]]  = mean(vapply(snapshot, FUN = function (x) { x[["mse"]] }, FUN.VALUE = numeric(1)))

			if (! silent) message("  >> Calculate new beta which gives an mse of ", model[["mse_average"]])

			if (registry[["actual_iteration"]] > 0) {
				stop_algo = c(
					registry[["actual_iteration"]] >= registry[["epochs"]],
					((mse_old - model[["mse_average"]]) / mse_old) <= registry[["mse_eps"]]
					)
			} else {
				stop_algo = FALSE
			}

			registry[["actual_iteration"]] = actual_iteration + epochs_at_once

			if (! registry[["save_all"]]) {
				if (! silent) message("  >> Removing ", actual_state, "\n")
					unlink(actual_state)
			}

			if (any(stop_algo)) { model[["done"]] = TRUE }

			save(list = "model", file = paste0(regis_dir, "/model.rds"))
			save(list = "registry", file = paste0(regis_dir, "/registry.rds"))

		} else {
			# If a file is missing do a gradient descent step and store the gradient:
			which_files_exists = file.exists(registry[["file_names"]]) 
			for (file in registry[["file_names"]][which_files_exists]) {

				if (! silent) { message("\tProcessing ", file) }

				data_in = registry[["file_reader"]](file)
				response = all.vars(registry[["formula"]])[attr(terms(registry[["formula"]], data = data_in), "response")]
				X_helper = model.matrix(registry[["formula"]], data = data_in)
				
				# Initialize model the very first time:
				if (! "beta" %in% names(model)) {
					model[["beta"]] = runif(ncol(X_helper)) 
					save(list = "model", file = paste0(regis_dir, "/model.rds"))
				}
				# Do a gradient descent step on the single dataset:
				model_temp = new(eval(parse(text = registry[["model"]])), X = X_helper, y = data_in[[response]])
				optimizer.fun = eval(parse(text = registry[["optimizer"]]))
				snapshot[[file]] = optimizer.fun(mod = model_temp, param_start = model[["beta"]], learning_rate = registry[["learning_rate"]], 
  				iters = epochs_at_once, trace = FALSE, warnings = FALSE)
			}
			save(list = "snapshot", file = actual_state)
		}
	} else {
		if (! silent) message("Nothing to do. Model is already fitted.")
	}
}