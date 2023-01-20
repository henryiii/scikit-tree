import numpy as np

cimport numpy as cnp
cnp.import_array()

from libc.string cimport memcpy

from sklearn.tree._utils cimport log
from sklearn.tree._utils cimport rand_int
from sklearn.tree._utils cimport rand_uniform
from sklearn.tree._utils cimport RAND_R_MAX

from ._sklearn_splitter cimport sort


cdef double INFINITY = np.inf

# Mitigate precision differences between 32 bit and 64 bit
cdef DTYPE_t FEATURE_THRESHOLD = 1e-7

# Constant to switch between algorithm non zero value extract algorithm
# in SparseSplitter
cdef DTYPE_t EXTRACT_NNZ_SWITCH = 0.1

cdef inline void _init_split(SplitRecord* self, SIZE_t start_pos) nogil:
    self.impurity_left = INFINITY
    self.impurity_right = INFINITY
    self.pos = start_pos
    self.feature = 0
    self.threshold = 0.
    self.improvement = -INFINITY


cdef class UnsupervisedSplitter(BaseSplitter):
    """Base class for unsupervised splitters."""

    cdef int init(
        self,
        const DTYPE_t[:, ::1] X,
        const DOUBLE_t[:] sample_weight
    ) except -1:
        self.rand_r_state = self.random_state.randint(0, RAND_R_MAX)
        cdef SIZE_t n_samples = X.shape[0]

        # Create a new array which will be used to store nonzero
        # samples from the feature of interest
        self.samples = np.empty(n_samples, dtype=np.intp)
        cdef SIZE_t[::1] samples = self.samples

        cdef SIZE_t i, j
        cdef double weighted_n_samples = 0.0
        j = 0

        for i in range(n_samples):
            # Only work with positively weighted samples
            if sample_weight is None or sample_weight[i] != 0.0:
                samples[j] = i
                j += 1

            if sample_weight is not None:
                weighted_n_samples += sample_weight[i]
            else:
                weighted_n_samples += 1.0

        # Number of samples is number of positively weighted samples
        self.n_samples = j
        self.weighted_n_samples = weighted_n_samples

        cdef SIZE_t n_features = X.shape[1]
        self.features = np.arange(n_features, dtype=np.intp)
        self.n_features = n_features

        self.feature_values = np.empty(n_samples, dtype=np.float32)
        self.constant_features = np.empty(n_features, dtype=np.intp)

        self.sample_weight = sample_weight

        self.X = X

        # initialize criterion
        self.criterion.init(
            self.sample_weight,
            self.weighted_n_samples,
            self.samples
        )

        # set sample pointers in criterion
        self.criterion.set_sample_pointers(
            self.start,
            self.end
        )
        return 0

    cdef int node_split(
        self,
        double impurity,
        SplitRecord* split,
        SIZE_t* n_constant_features
    ) nogil except -1:
        """Find the best split on node samples[start:end].

        This is a placeholder method. The majority of computation will be done
        here.

        It should return -1 upon errors.
        """
        pass


cdef class BestUnsupervisedSplitter(UnsupervisedSplitter):
    """"""
    def __reduce__(self):
        return (type(self), (self.criterion,
                             self.max_features,
                             self.min_samples_leaf,
                             self.min_weight_leaf,
                             self.random_state), self.__getstate__())

    cdef int node_split(
        self,
        double impurity,
        SplitRecord* split,
        SIZE_t* n_constant_features
    ) nogil except -1:
        """Find the best split on node samples[start:end].

        This is a placeholder method. The majority of computation will be done
        here.

        It should return -1 upon errors.

        Note: the function is an exact copy of the `BestSplitter.node_split` function
        because that function abstracts away the presence of `y` and hence can be used
        exactly as is. We cannot inherit until scikit-learn enables this functions to
        be cimportable.
        """
        # Find the best split
        cdef SIZE_t[::1] samples = self.samples
        cdef SIZE_t start = self.start
        cdef SIZE_t end = self.end

        cdef SIZE_t[::1] features = self.features
        cdef SIZE_t[::1] constant_features = self.constant_features
        cdef SIZE_t n_features = self.n_features

        cdef DTYPE_t[::1] Xf = self.feature_values
        cdef SIZE_t max_features = self.max_features
        cdef SIZE_t min_samples_leaf = self.min_samples_leaf
        cdef UINT32_t* random_state = &self.rand_r_state

        # XXX: maybe need to rename to something else
        cdef double min_weight_leaf = self.min_weight_leaf

        cdef SplitRecord best, current
        cdef double current_proxy_improvement = -INFINITY
        cdef double best_proxy_improvement = -INFINITY

        cdef SIZE_t f_i = n_features
        cdef SIZE_t f_j
        cdef SIZE_t p
        cdef SIZE_t i

        cdef SIZE_t n_visited_features = 0
        # Number of features discovered to be constant during the split search
        cdef SIZE_t n_found_constants = 0
        # Number of features known to be constant and drawn without replacement
        cdef SIZE_t n_drawn_constants = 0
        cdef SIZE_t n_known_constants = n_constant_features[0]
        # n_total_constants = n_known_constants + n_found_constants
        cdef SIZE_t n_total_constants = n_known_constants
        cdef SIZE_t partition_end

        _init_split(&best, end)

        # Sample up to max_features without replacement using a
        # Fisher-Yates-based algorithm (using the local variables `f_i` and
        # `f_j` to compute a permutation of the `features` array).
        #
        # Skip the CPU intensive evaluation of the impurity criterion for
        # features that were already detected as constant (hence not suitable
        # for good splitting) by ancestor nodes and save the information on
        # newly discovered constant features to spare computation on descendant
        # nodes.
        while (f_i > n_total_constants and  # Stop early if remaining features
                                            # are constant
                (n_visited_features < max_features or
                 # At least one drawn features must be non constant
                 n_visited_features <= n_found_constants + n_drawn_constants)):

            n_visited_features += 1

            # Loop invariant: elements of features in
            # - [:n_drawn_constant[ holds drawn and known constant features;
            # - [n_drawn_constant:n_known_constant[ holds known constant
            #   features that haven't been drawn yet;
            # - [n_known_constant:n_total_constant[ holds newly found constant
            #   features;
            # - [n_total_constant:f_i[ holds features that haven't been drawn
            #   yet and aren't constant apriori.
            # - [f_i:n_features[ holds features that have been drawn
            #   and aren't constant.

            # Draw a feature at random
            f_j = rand_int(n_drawn_constants, f_i - n_found_constants,
                           random_state)

            if f_j < n_known_constants:
                # f_j in the interval [n_drawn_constants, n_known_constants[
                features[n_drawn_constants], features[f_j] = features[f_j], features[n_drawn_constants]

                n_drawn_constants += 1
                continue

            # f_j in the interval [n_known_constants, f_i - n_found_constants[
            f_j += n_found_constants
            # f_j in the interval [n_total_constants, f_i[
            current.feature = features[f_j]

            # Sort samples along that feature; by
            # copying the values into an array and
            # sorting the array in a manner which utilizes the cache more
            # effectively.
            for i in range(start, end):
                Xf[i] = self.X[samples[i], current.feature]

            sort(&Xf[start], &samples[start], end - start)

            # check if we have found a "constant" feature
            if Xf[end - 1] <= Xf[start] + FEATURE_THRESHOLD:
                features[f_j], features[n_total_constants] = features[n_total_constants], features[f_j]

                n_found_constants += 1
                n_total_constants += 1
                continue

            f_i -= 1
            features[f_i], features[f_j] = features[f_j], features[f_i]

            # initialize feature vector for criterion to evaluate
            # GIL is needed since we are changing the criterion's internal memory
            with gil:
                self.criterion.init_feature_vec(Xf)

            # Evaluate all splits along the feature vector
            p = start

            while p < end:
                while p + 1 < end and Xf[p + 1] <= Xf[p] + FEATURE_THRESHOLD:
                    p += 1

                # (p + 1 >= end) or (X[samples[p + 1], current.feature] >
                #                    X[samples[p], current.feature])
                p += 1
                # (p >= end) or (X[samples[p], current.feature] >
                #                X[samples[p - 1], current.feature])

                if p >= end:
                    continue

                current.pos = p

                # Reject if min_samples_leaf is not guaranteed
                if (((current.pos - start) < min_samples_leaf) or
                        ((end - current.pos) < min_samples_leaf)):
                    continue

                self.criterion.update(current.pos)

                # Reject if min_weight_leaf is not satisfied
                if ((self.criterion.weighted_n_left < min_weight_leaf) or
                        (self.criterion.weighted_n_right < min_weight_leaf)):
                    continue

                current_proxy_improvement = self.criterion.proxy_impurity_improvement()

                if current_proxy_improvement > best_proxy_improvement:
                    best_proxy_improvement = current_proxy_improvement
                    # sum of halves is used to avoid infinite value
                    current.threshold = Xf[p - 1] / 2.0 + Xf[p] / 2.0

                    if (
                        current.threshold == Xf[p] or
                        current.threshold == INFINITY or
                        current.threshold == -INFINITY
                    ):
                        current.threshold = Xf[p - 1]

                    best = current  # copy

        # Reorganize into samples[start:best.pos] + samples[best.pos:end]
        if best.pos < end:
            partition_end = end
            p = start

            while p < partition_end:
                if self.X[samples[p], best.feature] <= best.threshold:
                    p += 1

                else:
                    partition_end -= 1

                    samples[p], samples[partition_end] = samples[partition_end], samples[p]

            self.criterion.reset()
            self.criterion.update(best.pos)
            self.criterion.children_impurity(&best.impurity_left,
                                             &best.impurity_right)
            best.improvement = self.criterion.impurity_improvement(
                impurity, best.impurity_left, best.impurity_right)

        # Respect invariant for constant features: the original order of
        # element in features[:n_known_constants] must be preserved for sibling
        # and child nodes
        memcpy(&features[0], &constant_features[0], sizeof(SIZE_t) * n_known_constants)

        # Copy newly found constant features
        memcpy(&constant_features[n_known_constants],
               &features[n_known_constants],
               sizeof(SIZE_t) * n_found_constants)

        # Return values
        split[0] = best
        n_constant_features[0] = n_total_constants
        return 0
