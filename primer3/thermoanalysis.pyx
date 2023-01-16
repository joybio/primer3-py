# Copyright (C) 2014-2020. Ben Pruitt & Nick Conway; Wyss Institute
# See LICENSE for full GPLv2 license.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
'''
primer3.thermoanalysis
~~~~~~~~~~~~~~~~~~~~~~

Contains Cython functions and classes that enable repeated thermodynamic
calculations using common calculation parameters.


Calculations are performed under the following paradigm:

1) Instantiate ThermoAnalysis object with appropriate parameters

    oligo_calc = ThermoAnalysis(mv_conc=50, dv_conc=0.2)

2) Use the object instance for subsequent calculations

    for primer in primer_list:
        print(oligo_calc.calcTm(primer))  # Print the melting temp

3) (optional) You can update an individual parameter at any time

    oligo_calc.mv_conc = 80  # Increaase the monovalent ion conc to 80 mM


'''
from libc.stdlib cimport (
    free,
    malloc,
)
from libc.string cimport strlen

import atexit
from typing import (
    Any,
    Dict,
    Union,
)

from .argdefaults import Primer3PyArguments

DEFAULT_P3_ARGS = Primer3PyArguments()

# ~~~~~~~~~~~~~~~~~~~~~~~~~ External C declarations ~~~~~~~~~~~~~~~~~~~~~~~~~ #

cdef extern from "oligotm.h":
    ctypedef enum tm_method_type:
        breslauer_auto      = 0
        santalucia_auto     = 1

    ctypedef enum salt_correction_type:
        schildkraut    = 0
        santalucia     = 1
        owczarzy       = 2

    double seqtm(
            const char*,
            double,
            double,
            double,
            double,
            int,
            tm_method_type,
            salt_correction_type,
    )


# ~~~~~~~~~~~~~~~ Utility functions to enforce utf8 encoding ~~~~~~~~~~~~~~~ #

cdef unsigned char[:] _chars(s):
    cdef unsigned char[:] o
    if isinstance(s, str):
        # encode to the specific encoding used inside of the module
        o = memoryview(bytearray((<str>s).encode('utf8')))
        return o
    return memoryview(s)

cdef inline bytes _bytes(s):
    # Note that this check gets optimized out by the C compiler and is
    # recommended over the IF/ELSE Cython compile-time directives
    # See: Cython/Includes/cpython/version.pxd
    if isinstance(s, str):
        # encode to the specific encoding used inside of the module
        return (<str>s).encode('utf8')
    else:
        return s

# ~~~~~~~~~ Load base thermodynamic parameters into memory from file ~~~~~~~~ #

def _loadThermoParams():
    cdef char*           p3_cfg_path_bytes_c
    cdef thal_results    thalres
    import os
    libprimer3_path = os.environ.get('PRIMER3HOME')
    p3_cfg_path = os.path.join(libprimer3_path, 'primer3_config/')
    p3_cfg_path_bytes = p3_cfg_path.encode('utf-8')
    p3_cfg_path_bytes_c = p3_cfg_path_bytes
    if get_thermodynamic_values(p3_cfg_path_bytes_c, &thalres) != 0:
        raise IOError(
            f'Could not load thermodynamic config file {p3_cfg_path}'
        )

_loadThermoParams()

def _cleanup():
    destroy_thal_structures()

atexit.register(_cleanup)

def precision(x, pts=None):
    return x if pts is None else round(x, pts)

# ~~~~~~~~~~~~~~ Thermodynamic calculations class declarations ~~~~~~~~~~~~~~ #

cdef class ThermoResult:
    ''' Class that wraps the ``thal_results`` struct from libprimer3
    to expose tm, dg, dh, and ds values that result from a ``calcHairpin``,
    ``calcHomodimer``, ``calcHeterodimer``, or ``calcEndStability``
    calculation.
    '''

    def __cinit__(self):
        self.thalres.no_structure = 0
        self.thalres.ds = self.thalres.dh = self.thalres.dg = 0.0
        self.thalres.align_end_1 = self.thalres.align_end_2 = 0

    @property
    def structure_found(self) -> bool:
        ''' Whether or not a structure (hairpin, dimer, etc) was found as a
        result of the calculation.
        '''
        return not bool(self.thalres.no_structure)

    @property
    def tm(self) -> float:
        ''' Melting temperature of the structure in deg. C '''
        return self.thalres.temp

    @property
    def ds(self) -> float:
        ''' deltaS (enthalpy) of the structure (cal/K*mol) '''
        return self.thalres.ds

    @property
    def dh(self) -> float:
        ''' deltaH (entropy) of the structure (cal/mol) '''
        return self.thalres.dh

    @property
    def dg(self) -> float:
        ''' deltaG (Gibbs free energy) of the structure (cal/mol) '''
        return self.thalres.dg

    @property
    def ascii_structure_lines(self):
        ''' ASCII structure representation split into indivudial lines

        e.g.,
            [u'SEQ\t         -    T CCT-   A   TTGCTTTGAAACAATTCACCATGCAGA',
             u'SEQ\t      TGC GATG G    GCT TGC                           ',
             u'STR\t      ACG CTAC C    CGA ACG                           ',
             u'STR\tAACCTT   T    T TTAT   G   TAGGCGAGCCACCAGCGGCATAGTAA-']
        '''
        if self.ascii_structure:
            return self.ascii_structure.strip('\n').split('\n')
        else:
            return None

    def checkExc(self) -> ThermoResult:
        ''' Check the ``.msg`` attribute of the internal thalres struct and
        raise a ``RuntimeError`` exception if it is not an empty string.
        Otherwise, return a reference to the current object.

        Raises:
            RuntimeError: Message of internal C error
        '''
        if len(self.thalres.msg):
            raise RuntimeError(self.thalres.msg)
        else:
            return self

    def __repr__(self) -> str:
        ''' Human-readable representation of the object '''
        return (
            f'ThermoResult(structure_found={self.structure_found}, '
            f'tm={self.tm:0.2f}, dg={self.dg:0.2f}, '
            f'dh={self.dh:0.2f}, ds={self.ds:0.2f})'
        )

    def __str__(self) -> str:
        ''' Wraps ``__repr`` '''
        return self.__repr__()

    def todict(self, pts=None) -> Dict[str, Any]:
        '''
        Args:
            pts: precision to round floats to

        Returns:
            dictionary form of the ``ThermoResult``
        '''
        return {
            'structure_found': self.structure_found,
            'ascii_structure': self.ascii_structure,
            'tm': precision(self.tm, pts),
            'dg': precision(self.dg, pts),
            'dh': precision(self.dh, pts),
            'ds': precision(self.ds, pts)
        }


def _conditional_get_enum_int(
        arg_name: str,
        arg_value: Union[str, int],
        dict_obj: Dict[str, int],
) -> int:
    '''Helper function to conditionally resolve an argument value enum value
    using either key or to just return the key if it is an integer

    Args:
        arg_name: Name of argument resolving
        arg_value: integer value or string name key mapping to an integer
        dict_obj: dictionary mapping the string to an int

    Returns:
        integer value for the key in the map

    Raises:
        ValueError: arg_value missing in the map ``dict_obj``
        TypeError: invalid type for the key
    '''
    if isinstance(arg_value, (int, long)):
        return arg_value
    elif isinstance(arg_value, str):
        if arg_value not in dict_obj:
            raise ValueError(
                f'{arg_name}: {arg_value} argument not in {dict_obj}',
            )
        return dict_obj[arg_value]
    raise TypeError(
        f'{arg_name}: {arg_value} invalid type {type(arg_value)}',
    )


cdef class ThermoAnalysis:
    ''' Python class that serves as the entry point for thermodynamic
    calculations. Should be instantiated with the proper thermodynamic
    parameters for seqsequence calculations (salt concentrations, correction
    methods, limits, etc.). See module docstring for more information.
    '''

    tm_methods_dict = {
        'breslauer': 0,
        'santalucia': 1
    }

    salt_correction_methods_dict = {
        'schildkraut': 0,
        'santalucia': 1,
        'owczarzy': 2
    }
    # NOTE: Unused but here as a reference
    thal_alignment_types_dict = {
        'thal_alignment_any': 1,
        'thal_alignment_end1': 2,
        'thal_alignment_end2': 3,
        'thal_alignment_hairpin': 4,
    }

    def __cinit__(
                self,
                mv_conc: float = DEFAULT_P3_ARGS.mv_conc,
                dv_conc: float = DEFAULT_P3_ARGS.dv_conc,
                dntp_conc: float = DEFAULT_P3_ARGS.dntp_conc,
                dna_conc: float = DEFAULT_P3_ARGS.dna_conc,
                temp_c: float = DEFAULT_P3_ARGS.temp_c,
                max_loop: int = DEFAULT_P3_ARGS.max_loop,
                temp_only: int = DEFAULT_P3_ARGS.temp_only,
                debug: int = 0,
                max_nn_length: int = DEFAULT_P3_ARGS.max_nn_length,
                tm_method: Union[int, str] = DEFAULT_P3_ARGS.tm_method_int,
                salt_correction_method: Union[int, str] = \
                    DEFAULT_P3_ARGS.salt_corrections_method_int,
        ):
        '''
        NOTE: this class uses properties to enable multi type value assignment
        as a convenience to enable string keys to set the integer values of
        struct fields required in the `thalargs` fields
        Args:
            thal_type: type of thermodynamic alignment, a string name key or
                integer value member of the thal_alignment_types_dict dict::
                {
                    'thal_alignment_any': 1,
                    'thal_alignment_end1': 2,
                    'thal_alignment_end2': 3,
                    'thal_alignment_hairpin': 4,
                }
            mv_conc: concentration of monovalent cations (mM)
            dv_conc: concentration of divalent cations (mM)
            dntp_conc: concentration of dNTP-s (mM)
            dna_conc: concentration of oligonucleotides (mM)
            temp_c: temperature from which hairpin structures will be
                calculated (C)
            max_loop: maximum size of loop size of bases to consider in calcs
            temp_only: print only temp to stderr
            debug: if non zero, print debugging info to stderr
            max_nn_length: The maximum sequence length for using the nearest
                neighbor model (as implemented in oligotm.  For
                sequences longer than this, `seqtm` uses the "GC%" formula
                implemented in long_seq_tm.  Use only when calling the
                ``ThermoAnalysis.calcTm`` method
            tm_method: Type of temperature method, a string name key or integer
                value member of the tm_methods_dict dict::
                {
                    'breslauer': 0,
                    'santalucia': 1
                }
            salt_correction_method: Type of salt correction method, a string
                name key or integer value member of the
                salt_correction_methods_dict::
                {
                    'schildkraut': 0,
                    'santalucia': 1,
                    'owczarzy': 2
                }
            '''
        self.thalargs.mv = mv_conc
        self.thalargs.dv = dv_conc
        self.thalargs.dntp = dntp_conc
        self.thalargs.dna_conc = dna_conc
        self.thalargs.temp = temp_c + 273.15  # Convert to Kelvin
        self.thalargs.maxLoop = max_loop
        self.thalargs.temponly = temp_only
        self.thalargs.debug = debug

        self.max_nn_length = max_nn_length

        self.tm_method = tm_method
        self.salt_correction_method = salt_correction_method

        # Create reverse maps for properties
        self._tm_methods_int_dict = {
            v: k
            for k, v in self.tm_methods_dict.items()
        }
        self._salt_correction_methods_int_dict = {
            v: k
            for k, v in self.salt_correction_methods_dict.items()
        }

    # ~~~~~~~~~~~~~~~~~~~~~~ Property getters / setters ~~~~~~~~~~~~~~~~~~~~~ #
    @property
    def mv_conc(self) -> float:
        ''' Concentration of monovalent cations (mM) '''
        return self.thalargs.mv

    @mv_conc.setter
    def mv_conc(self, value: float):
        self.thalargs.mv = value

    @property
    def dv_conc(self) -> float:
        ''' Concentration of divalent cations (mM) '''
        return self.thalargs.dv

    @dv_conc.setter
    def dv_conc(self, value: float):
        self.thalargs.dv = value

    @property
    def dntp_conc(self) -> float:
        ''' Concentration of dNTPs (mM) '''
        return self.thalargs.dntp

    @dntp_conc.setter
    def dntp_conc(self, value: float):
        self.thalargs.dntp = value

    @property
    def dna_conc(self) -> float:
        ''' Concentration of DNA oligos (nM) '''
        return self.thalargs.dna_conc

    @dna_conc.setter
    def dna_conc(self, value: float):
            self.thalargs.dna_conc = value

    @property
    def temp(self) -> float:
        ''' Simulation temperature (deg. C) '''
        return self.thalargs.temp - 273.15

    @temp.setter
    def temp(self, value: Union[int, float]):
        ''' Store in degrees Kelvin '''
        self.thalargs.temp = value + 273.15

    @property
    def max_loop(self) -> int:
        ''' Maximum hairpin loop size (bp) '''  # TODO: Is bp correct here?
        return self.thalargs.maxLoop

    @max_loop.setter
    def max_loop(self, value: int):
        if 0 <= value < 31:
            self.thalargs.maxLoop = value
        else:
            raise ValueError(f'max_loop must be less than 31, received {value}')

    @property
    def tm_method(self) -> str:
        '''Method used to calculate melting temperatures. May be provided as
        a string (see tm_methods_dict) or the respective integer representation.
        '''
        return self._tm_methods_int_dict[self._tm_method]

    @tm_method.setter
    def tm_method(self, value: Union[int, str]):
        self._tm_method = _conditional_get_enum_int(
            'tm_method',
            value,
            ThermoAnalysis.tm_methods_dict,
        )

    @property
    def salt_correction_method(self) -> str:
        ''' Method used for salt corrections applied to melting temperature
        calculations. May be provided as a string (see
        salt_correction_methods_dict) or the respective integer representation.
        '''
        return self._salt_correction_method

    @salt_correction_method.setter
    def salt_correction_method(self, value: Union[int, str]):
        self._salt_correction_method = _conditional_get_enum_int(
            'salt_correction_method',
            value,
            ThermoAnalysis.salt_correction_methods_dict,
        )

    # ~~~~~~~~~~~~~~ Thermodynamic calculation instance methods ~~~~~~~~~~~~~ #

    cdef inline ThermoResult calcHeterodimer_c(
            ThermoAnalysis self,
            unsigned char *s1,
            unsigned char *s2,
            bint output_structure,
    ):
        '''
        C only heterodimer computation

        Args:
            s1: sequence string 1
            s2: sequence string 2
            output_structure: If True, build output structure.

        Returns:
            Computed heterodimer result
        '''
        cdef ThermoResult tr_obj = ThermoResult()
        cdef char* c_ascii_structure = NULL

        self.thalargs.dimer = 1
        self.thalargs.type = <thal_alignment_type> 1 # thal_alignment_any
        if (output_structure == 1):
            c_ascii_structure = <char *>malloc(
                (strlen(<const char*>s1) + strlen(<const char*>s2)) * 4 + 24)
            c_ascii_structure[0] = b'\0'
        thal(
            <const unsigned char*> s1,
            <const unsigned char*> s2,
            <const thal_args *> &(self.thalargs),
            &(tr_obj.thalres),
            1 if c_ascii_structure else 0,
            c_ascii_structure
        )
        if (output_structure == 1):
            try:
                tr_obj.ascii_structure = c_ascii_structure.decode('utf8')
            finally:
                free(c_ascii_structure)
        return tr_obj

    cpdef ThermoResult calcHeterodimer(
            ThermoAnalysis self,
            object seq1,
            object seq2,
            bint output_structure = False
        ):
        ''' Calculate the heterodimer formation thermodynamics of two DNA
        sequences, ``seq1`` and ``seq2``

        Args:
            s1: (str | bytes) sequence string 1
            s2: (str | bytes) sequence string 2
            output_structure: If True, build output structure.

        Returns:
            Computed heterodimer ``ThermoResult``
        '''
        # first convert any unicode to a byte string and then
        # cooerce to a unsigned char * see:
        # http://docs.cython.org/src/tutorial/strings.html#encoding-text-to-bytes
        py_s1 = <bytes> _bytes(seq1)
        cdef unsigned char* s1 = py_s1
        py_s2 = <bytes> _bytes(seq2)
        cdef unsigned char* s2 = py_s2
        return ThermoAnalysis.calcHeterodimer_c(
            <ThermoAnalysis> self,
            s1,
            s2,
            output_structure,
        )

    cpdef tuple misprimingCheck(
            ThermoAnalysis self,
            object putative_seq,
            object sequences,
            double tm_threshold,
    ):
        '''
        Calculate the heterodimer formation thermodynamics of a DNA
        sequence, ``putative_seq`` with a list of sequences relative to
        a melting temperature threshold

        Args:
            putative_seq: (str | bytes) sequence to check
            sequences: (Iterable[str | bytes]) Iterable of sequence strings to
                check against
            tm_threshold: melting temperature threshold

        Returns:
            Tuple[bool, int, float] of form::
                is_offtarget (bool),
                max_offtarget_seq_idx (int),
                max_offtarget_tm (double)
        '''
        cdef:
            bint is_offtarget = False
            Py_ssize_t i
            double max_offtarget_tm = 0
            double offtarget_tm
            unsigned char* s2
            Py_ssize_t max_offtarget_seq_idx = -1

            bytes py_s2
            bytes py_s1 = <bytes> _bytes(putative_seq)
            unsigned char* s1 = py_s1

        for i, seq in enumerate(sequences):
            py_s2 = <bytes> _bytes(seq)
            s2 = py_s2
            offtarget_tm = ThermoAnalysis.calcHeterodimer_c(
                <ThermoAnalysis> self,
                s1,
                s2,
                0,
            ).tm
            if offtarget_tm > max_offtarget_tm:
                max_offtarget_seq_idx = i
                max_offtarget_tm = offtarget_tm
            if offtarget_tm > tm_threshold:
                is_offtarget = True
                break
        return is_offtarget, max_offtarget_seq_idx, max_offtarget_tm

    cdef inline ThermoResult calcHomodimer_c(
            ThermoAnalysis self,
            unsigned char *s1,
            bint output_structure,
    ):
        '''
        C only homodimer computation

        Args:
            s1: sequence string 1
            output_structure: If True, build output structure.

        Returns:
            Computed homodimer ``ThermoResult``
        '''
        cdef:
            ThermoResult tr_obj = ThermoResult()
            char* c_ascii_structure = NULL

        self.thalargs.dimer = 1
        self.thalargs.type = <thal_alignment_type> 1 # thal_alignment_any
        if output_structure == 1:
            c_ascii_structure = <char *>malloc(
                (strlen(<const char*>s1) * 8 + 24)
            )
            c_ascii_structure[0] = b'\0'
        thal(
            <const unsigned char*> s1,
            <const unsigned char*> s1,
            <const thal_args *> &(self.thalargs),
            &(tr_obj.thalres),
            1 if c_ascii_structure else 0,
            c_ascii_structure
        )
        if output_structure == 1:
            try:
                tr_obj.ascii_structure = c_ascii_structure.decode('utf8')
            finally:
                free(c_ascii_structure)
        return tr_obj

    cpdef ThermoResult calcHomodimer(
            ThermoAnalysis self,
            object seq1,
            bint output_structure = False,
    ):
        ''' Calculate the homodimer formation thermodynamics of a DNA
        sequence, ``seq1``

        Args:
            seq1: (str | bytes) sequence string 1
            output_structure: If True, build output structure.

        Returns:
            Computed homodimer ``ThermoResult``
        '''
        # first convert any unicode to a byte string and then
        # cooerce to a unsigned char *
        py_s1 = <bytes> _bytes(seq1)
        cdef unsigned char* s1 = py_s1
        return ThermoAnalysis.calcHomodimer_c(
            <ThermoAnalysis> self,
            s1,
            output_structure,
        )

    cdef inline ThermoResult calcHairpin_c(
            ThermoAnalysis self,
            unsigned char *s1,
            bint output_structure,
    ):
        '''
        C only hairpin computation

        Args:
            s1: sequence string 1
            output_structure: If True, build output structure.

        Returns:
            Computed hairpin ``ThermoResult``
        '''
        cdef:
            ThermoResult tr_obj = ThermoResult()
            char* c_ascii_structure = NULL

        self.thalargs.dimer = 0
        self.thalargs.type = <thal_alignment_type> 4 # thal_alignment_hairpin
        if output_structure == 1:
            c_ascii_structure = <char *>malloc(
                (strlen(<const char*>s1) * 2 + 24)
            )
            c_ascii_structure[0] = '\0';
        thal(
            <const unsigned char*> s1,
            <const unsigned char*> s1,
            <const thal_args *> &(self.thalargs),
            &(tr_obj.thalres),
            1 if c_ascii_structure else 0,
            c_ascii_structure
        )
        if output_structure == 1:
            try:
                tr_obj.ascii_structure = c_ascii_structure.decode('utf8')
            finally:
                free(c_ascii_structure)
        return tr_obj

    cpdef ThermoResult calcHairpin(
            ThermoAnalysis self,
            object seq1,
            bint output_structure = False,
    ):
        ''' Calculate the hairpin formation thermodynamics of a DNA
        sequence, ``seq1``

        Args:
            seq1: (str | bytes) sequence string 1
            output_structure: If True, build output structure.

        Returns:
            Computed hairpin ``ThermoResult``
        '''
        # first convert any unicode to a byte string and then
        # cooerce to a unsigned char *
        py_s1 = <bytes> _bytes(seq1)
        cdef unsigned char* s1 = py_s1
        return ThermoAnalysis.calcHairpin_c(
            <ThermoAnalysis> self,
            s1,
            output_structure,
        )

    cdef inline ThermoResult calcEndStability_c(
            ThermoAnalysis self,
            unsigned char *s1,
            unsigned char *s2,
    ):
        '''
        C only end stability computation

        Args:
            s1: sequence string 1
            s2: sequence string 2

        Returns:
            Computed end stability ``ThermoResult``
        '''
        cdef ThermoResult tr_obj = ThermoResult()

        self.thalargs.dimer = 1
        self.thalargs.type = <thal_alignment_type> 2 # thal_alignment_end1
        thal(<const unsigned char*> s1, <const unsigned char*> s2,
         <const thal_args *> &(self.thalargs), &(tr_obj.thalres), 0, NULL)
        return tr_obj

    def calcEndStability(
            ThermoAnalysis self,
            seq1: Union[str, bytes],
            seq2: Union[str, bytes],
    ) -> ThermoResult:
        ''' Calculate the 3' end stability of DNA sequence `seq1` against DNA
        sequence `seq2`

        Args:
            seq1: sequence string 1
            seq2: sequence string 2

        Returns:
            Computed end stability ``ThermoResult``
        '''
        # first convert any unicode to a byte string and then
        # cooerce to a unsigned char * see:
        # http://docs.cython.org/src/tutorial/strings.html#encoding-text-to-bytes
        py_s1 = <bytes> _bytes(seq1)
        cdef unsigned char* s1 = py_s1
        py_s2 = <bytes> _bytes(seq2)
        cdef unsigned char* s2 = py_s2
        return ThermoAnalysis.calcEndStability_c(<ThermoAnalysis> self, s1, s2)

    cdef inline double calcTm_c(ThermoAnalysis self, char *s1):
        '''
        C only Tm computation

        Args:
            s1: sequence string 1

        Returns:
            floating point Tm result
        '''
        cdef thal_args *ta = &self.thalargs
        return seqtm(
            <const char*> s1,
            ta.dna_conc,
            ta.mv,
            ta.dv,
            ta.dntp,
            self.max_nn_length,
            <tm_method_type> self._tm_method,
            <salt_correction_type> self._salt_correction_method,
        )

    def calcTm(ThermoAnalysis self, seq1: Union[str, bytes]) -> float:
        ''' Calculate the melting temperature (Tm) of a DNA sequence (deg. C).

        Args:
            seq1: (str | bytes) sequence string 1

        Returns:
            floating point Tm result
        '''
        # first convert any unicode to a byte string and then
        # cooerce to a unsigned char *
        py_s1 = <bytes> _bytes(seq1)
        cdef char* s1 = py_s1
        return ThermoAnalysis.calcTm_c(<ThermoAnalysis> self, s1)

    def todict(self) -> Dict[str, Any]:
        '''
        Returns:
            dictionary form of the ``ThermoAnalysis`` instance
        '''
        return {
            'mv_conc':      self.mv_conc,
            'dv_conc':      self.dv_conc,
            'dntp_conc':    self.dntp_conc,
            'dna_conc':     self.dna_conc,
            'temp_c':       self.temp,
            'max_loop':     self.max_loop,
            'temp_only':    self.temp_only,
            'debug':        self.thalargs.debug,
            'max_nn_length': self.max_nn_length,
            'tm_method':    self.tm_method,
            'salt_correction_method': self.salt_correction_method
        }
